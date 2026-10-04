{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.mdbook;
  traefik = config.MODULES.networking.traefik;
  idp = config.MODULES.security.idp;

  path = "/mdbook";
  vhost = "mdbook.internal";
  nginxUrl = "http://127.0.0.1:${toString config.PORTS.mdbook}";
  hookId = "mdbook-update";

  # What nginx serves always goes through this symlink, swapped in one rename by the update
  # job, so a half-extracted tarball is never visible.
  current = "${cfg.dir}/current";

  update = pkgs.writeShellApplication {
    name = "mdbook-update";
    runtimeInputs = with pkgs; [curl gnutar gzip coreutils findutils];
    text = ''
      cd ${cfg.dir}
      mkdir -p releases
      incoming=$(mktemp -d .incoming.XXXXXX)
      trap 'rm -rf "$incoming"' EXIT

      curl -fsSL --retry 3 --max-filesize 1073741824 -o "$incoming/docs.tar.gz" ${lib.escapeShellArg cfg.source.url}

      release="releases/$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir "$incoming/tree"
      tar -xzf "$incoming/docs.tar.gz" -C "$incoming/tree" --no-same-owner --no-same-permissions
      if [ ! -f "$incoming/tree/html/index.html" ]; then
        echo "tarball has no html/index.html - keeping the current release" >&2
        exit 1
      fi
      chmod -R a+rX "$incoming/tree"
      mv "$incoming/tree" "$release"

      ln -sfn "$release" .current.new
      mv -T .current.new current
      echo "now serving $release"

      # Keep the last three, for a quick manual rollback (re-point `current`).
      find releases -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf
    '';
  };
in {
  options.MODULES.services.mdbook = {
    enable = mkEnableOption ''
      the baumit-docs site at <public base URL>/mdbook, on Traefik's Funnel-backed public entry
      point, behind a git.robo4you.at login (oauth2-proxy against MODULES.security.idp). It is
      kept in step with the docs package by a Forgejo webhook. Tailnet-only until an OAuth2 app
      is configured
    '';

    dir = mkOption {
      type = types.str;
      default = "/var/lib/mdbook";
      description = ''
        State directory: `releases/<timestamp>/` holds each extracted tarball, `current` points
        at the one being served. The tarball's `html/` is served as /mdbook/ and its `pdf/` as
        /mdbook/pdf/.
      '';
    };

    source.url = mkOption {
      type = types.str;
      default = "https://git.robo4you.at/api/packages/akos.papp/generic/baumit-docs/latest/baumit-docs.tar.gz";
      description = "Tarball to fetch (public, so no token). Must contain html/index.html.";
    };

    source.packageName = mkOption {
      type = types.str;
      default = "baumit-docs";
      description = "Forgejo package whose `created` events trigger an update.";
    };

    webhookSecret = mkOption {
      type = types.str;
      default = "mdbook/webhook_secret";
      description = ''
        sops secret shared with the Forgejo webhook. Forgejo signs every delivery with it
        (X-Forgejo-Signature, HMAC-SHA256 of the body), and anything unsigned or signed with
        another secret is rejected before the update job is touched.
      '';
    };

    allowedGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["robo4you" "robo4you:docs"];
      description = ''
        Forgejo organisations (`org`) or teams (`org:team`) allowed in, from the `groups` claim
        git.robo4you.at puts in its tokens. Empty lets in every account on that Forgejo.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.mdbook = {
      isSystemUser = true;
      group = "mdbook";
    };
    users.groups.mdbook = {};

    # World-readable: nginx reads it, the update job (as mdbook) writes it.
    systemd.tmpfiles.rules = ["d ${cfg.dir} 0755 mdbook mdbook - -"];

    services.nginx = {
      enable = true;
      virtualHosts.${vhost} = {
        listen = [
          {
            addr = "127.0.0.1";
            port = config.PORTS.mdbook;
          }
        ];
        extraConfig = ''
          # Redirects relative to whatever host the browser used, not this loopback listener.
          absolute_redirect off;
        '';
        locations."= ${path}".return = "301 ${path}/";
        locations."${path}/pdf/".alias = "${current}/pdf/";
        locations."${path}/" = {
          alias = "${current}/html/";
          index = "index.html";
        };
      };
    };

    # --- Updates --------------------------------------------------------------------------
    systemd.services.mdbook-update = {
      description = "Fetch and publish the latest ${cfg.source.packageName} package";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Also once a day, in case a webhook delivery was missed.
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${update}/bin/mdbook-update";
        User = "mdbook";
        Group = "mdbook";
        UMask = "0022";
        ReadWritePaths = [cfg.dir];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    # The endpoint Forgejo calls. It never runs the update itself: a valid delivery only asks
    # systemd to start mdbook-update (allowed by the polkit rule below and nothing else), so the
    # internet-facing process has no write access to anything.
    services.webhook = {
      enable = true;
      ip = "127.0.0.1";
      port = config.PORTS.webhook;
      hooksTemplated.${hookId} = builtins.toJSON {
        id = hookId;
        execute-command = "${pkgs.systemd}/bin/systemctl";
        pass-arguments-to-command = map (a: {
          source = "string";
          name = a;
        }) ["start" "--no-block" "mdbook-update.service"];
        response-message = "update queued";
        trigger-rule-mismatch-http-response-code = 403;
        trigger-rule.and = [
          {
            match = {
              type = "payload-hmac-sha256";
              # Backticks, not quotes: this ends up inside JSON, which would escape quotes into
              # something Go's template parser rejects.
              secret = "{{ getenv `MDBOOK_WEBHOOK_SECRET` }}";
              parameter = {
                source = "header";
                name = "X-Forgejo-Signature";
              };
            };
          }
          {
            match = {
              type = "value";
              value = "created";
              parameter = {
                source = "payload";
                name = "action";
              };
            };
          }
          {
            match = {
              type = "value";
              value = cfg.source.packageName;
              parameter = {
                source = "payload";
                name = "package.name";
              };
            };
          }
        ];
      };
    };
    sops.secrets.${cfg.webhookSecret} = {};
    sops.templates."webhook.env" = {
      content = "MDBOOK_WEBHOOK_SECRET=${config.sops.placeholder.${cfg.webhookSecret}}";
      restartUnits = ["webhook.service"];
    };
    systemd.services.webhook.serviceConfig = {
      EnvironmentFile = config.sops.templates."webhook.env".path;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      RestrictNamespaces = true;
      LockPersonality = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = ["@system-service"];
    };
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "mdbook-update.service" &&
            action.lookup("verb") == "start" &&
            subject.user == "${config.services.webhook.user}") {
          return polkit.Result.YES;
        }
      });
    '';

    # --- Login ----------------------------------------------------------------------------
    services.oauth2-proxy = mkIf idp.enabled {
      enable = true;
      # Generic OIDC: git.robo4you.at (Forgejo) publishes a standard discovery document.
      provider = "oidc";
      oidcIssuerUrl = idp.issuer;
      scope = "openid email profile groups";
      # The client ID comes from sops too, through the env file below.
      keyFile = config.sops.templates."oauth2-proxy.env".path;
      clientSecretFile = config.sops.secrets.${idp.clientSecretSecret}.path;
      cookie = {
        secretFile = config.sops.secrets."mdbook/oauth2_cookie_secret".path;
        secure = true;
      };
      httpAddress = "http://127.0.0.1:${toString config.PORTS.oauth2Proxy}";
      # Everything oauth2-proxy serves itself (sign-in, callback) under /mdbook too, so the
      # one public route covers it.
      proxyPrefix = "${path}/oauth2";
      redirectURL = traefik.public.urlOf "${path}/oauth2/callback";
      # Trailing slash matters: without it oauth2-proxy matches the path exactly, so only the
      # bare /mdbook reached nginx and everything under it was oauth2-proxy's own 404.
      upstream = ["${nginxUrl}${path}/"];
      reverseProxy = true;
      # Only Traefik on this host (via loopback, the sole listen address) may set X-Forwarded-*.
      trustedProxyIP = ["127.0.0.1"];
      email.domains = ["*"];
      # The module's default ("force") would ask for consent on every login, and nginx has no
      # use for credentials passed along as basic auth.
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig =
        {
          skip-provider-button = true;
          code-challenge-method = "S256";
          cookie-path = path;
          metrics-address = "127.0.0.1:${toString config.PORTS.prometheusOauth2Proxy}";
        }
        // lib.optionalAttrs (cfg.allowedGroups != []) {
          allowed-group = cfg.allowedGroups;
        };
    };

    sops.secrets.${idp.clientSecretSecret} = mkIf idp.enabled {};
    sops.secrets.${idp.clientIdSecret} = mkIf idp.enabled {};
    sops.templates."oauth2-proxy.env" = mkIf idp.enabled {
      content = "OAUTH2_PROXY_CLIENT_ID=${config.sops.placeholder.${idp.clientIdSecret}}";
      restartUnits = ["oauth2-proxy.service"];
    };
    sops.secrets."mdbook/oauth2_cookie_secret" = mkIf idp.enabled {};

    MODULES.security.idp.redirectUris = [(traefik.public.urlOf "${path}/oauth2/callback")];

    MODULES.networking.traefik.public = {
      enable = true;
      routes.mdbook = {
        pathPrefix = path;
        target =
          if idp.enabled
          then config.services.oauth2-proxy.httpAddress
          else nginxUrl;
        tailnetOnly = !idp.enabled;
      };
      # Public on purpose - Forgejo has to reach it - and safe for that reason: deliveries
      # without the shared secret's signature get a 403 and change nothing.
      routes.webhook = {
        pathPrefix = "/hooks";
        target = "127.0.0.1:${toString config.PORTS.webhook}";
      };
    };
  };
}
