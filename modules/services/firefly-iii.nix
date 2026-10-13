{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.firefly-iii;

  fireflyV3I18nGen = pkgs.writeText "ff3-json-translations.php" ''
    <?php
    declare(strict_types=1);

    // Mirrors JC5/firefly-iii-dev app/Command/GenLanguageJson.php for version v3:
    // builds public/v3/i18n/<locale>.json from config/translations.php + resources/lang/.

    $root = $argv[1];
    $cfg  = require $root . '/config/translations.php';

    function enString(string $root, string $file, string $key): string
    {
        $eFileName = sprintf('%s/resources/lang/en_US/%s.php', $root, $file);
        if (!file_exists($eFileName) || !is_file($eFileName)) {
            return sprintf('(!%s.%s!)', $file, $key);
        }
        $loadLanguage = require $eFileName;
        if (!array_key_exists($key, $loadLanguage)) {
            return sprintf('(%s.%s)', $file, $key);
        }
        return (string) $loadLanguage[$key];
    }

    foreach ($cfg['languages'] as $language) {
        $content = [];
        foreach ($cfg['json']['v3'] as $file => $strings) {
            $eFileName = sprintf('%s/resources/lang/%s/%s.php', $root, $language, $file);
            if (!file_exists($eFileName) || !is_file($eFileName)) {
                $content[$file] = [];
                continue;
            }
            $loadLanguage = require $eFileName;
            $ns           = [];
            foreach (array_unique($strings) as $key) {
                $translation = $loadLanguage[$key] ?? false;
                if (false === $translation) {
                    $translation = enString($root, $file, $key);
                }
                $ns[$key] = (string) $translation;
            }
            $content[$file] = $ns;
        }
        if (!array_key_exists('config', $content) || [] === $content['config']) {
            continue;
        }
        $code = $content['config']['html_language'];
        $json = json_encode($content, JSON_PRETTY_PRINT, 16);
        $dash = str_replace('_', '-', $language);
        foreach (array_unique([$code, $dash]) as $dest) {
            file_put_contents(sprintf('%s/public/v3/i18n/%s.json', $root, $dest), $json);
        }
    }
  '';

  # Firefly III's own user/database name. The nixpkgs module only creates the system user when
  # `services.firefly-iii.user` is left at this default, and Postgres' default `local all all peer`
  # authentication maps a system user onto the database role of the same name - so reusing the one
  # name for both is what lets the app reach its database over the unix socket with no password
  # (and therefore no second secret to manage) at all.
  dbName = "firefly-iii";
in {
  options.MODULES.services.firefly-iii = {
    enable = mkEnableOption "Firefly III personal finance manager";

    siteOwner = mkOption {
      type = types.str;
      default = "admin@example.com";
      description = "Address Firefly III reports as the site owner in errors and outgoing mail";
    };

    homepageWidget.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Show Firefly III's net-worth/budget widget on the homepage dashboard. Off by default
        because it needs an API token that can only be created from inside a *running* Firefly III
        (Options -> Profile -> OAuth -> Personal Access Tokens), which doesn't exist yet on a first
        deploy. Once it does, put the token in sops as `firefly-iii/homepage-api-token` and flip
        this on - enabling it without that secret present will fail activation.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Laravel's application key: it encrypts session cookies and every field Firefly III stores
    # encrypted, so it has to stay stable for the lifetime of the data - rotating it after the
    # first transaction is entered makes the existing rows undecryptable.
    sops.secrets."firefly-iii/app-key" = {
      owner = config.services.firefly-iii.user;
      mode = "0400";
    };

    services.firefly-iii = {
      enable = true;
      enableNginx = true;
      virtualHost = "firefly-iii";

      # Upstream generates public/v3/i18n/<locale>.json in its release pipeline only
      # (resources/lang PHP -> JSON, gitignored, committed by nothing), and nixpkgs never runs
      # that step - worse, the release tarball it *does* download for resources/lang is the old
      # v6.7.7 asset which has no public/v3 at all. The v3 frontend fetches those JSON files at
      # runtime; on the 404 i18next hands back raw keys, date-fns gets 'config.month_and_day_fns'
      # as a format string, throws, and every dashboard chart tick renders "(DATE ERROR)" while
      # tooltips leak 'firefly.*' keys. Regenerate the files here from the same sources upstream
      # uses - $out/config/translations.php (list of languages + expected strings per namespace)
      # and $out/resources/lang - mirroring JC5/firefly-iii-dev's GenLanguageJson.
      package = pkgs.firefly-iii.overrideAttrs (final: prev: {
        postInstall =
          prev.postInstall
          + ''
            chmod -R u+w $out/public/v3/i18n
            php ${fireflyV3I18nGen} "$out"
          '';
      });

      settings = {
        APP_KEY_FILE = config.sops.secrets."firefly-iii/app-key".path;
        APP_ENV = "production";
        # Must match the externally visible URL, since Laravel builds every link and asset URL
        # from it.
        APP_URL = config.MODULES.networking.traefik.urlOf "firefly";
        SITE_OWNER = cfg.siteOwner;
        # Traefik terminates TLS upstream and talks plain HTTP to nginx here; without trusting the
        # forwarded headers Firefly III would decide the request was insecure and redirect-loop
        # trying to "upgrade" it back to https.
        TRUSTED_PROXIES = "**";
        LOG_CHANNEL = "stdout";

        DB_CONNECTION = "pgsql";
        DB_DATABASE = dbName;
        DB_USERNAME = dbName;
        # DB_HOST is left at the module default (/run/postgresql), i.e. the local unix socket.
      };

      # php-fpm's own status endpoint, scraped by the exporter wired up in prometheus.nix. Only
      # reachable over the pool's unix socket, never through nginx.
      poolConfig."pm.status_path" = "/status";
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [dbName];
      ensureUsers = [
        {
          name = dbName;
          ensureDBOwnership = true;
        }
      ];
    };

    # The nixpkgs module's vhost has no listener of its own; pin it to localhost on our port so
    # nginx doesn't fall back to 0.0.0.0:80 and collide with Traefik.
    services.nginx.virtualHosts.${config.services.firefly-iii.virtualHost}.listen = [
      {
        addr = "127.0.0.1";
        port = config.PORTS.fireflyIii;
      }
    ];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.firefly = "127.0.0.1:${toString config.PORTS.fireflyIii}";
  };
}
