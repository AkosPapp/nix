{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;

  cfg = config.MODULES.services.open-webui;

  # The key source: a nix-minted per-service key file (gateway host, audit #7) OR the sops
  # mount (the default everywhere). localGatewayKey gates the whole env-file block either
  # way; the two sources are mutually exclusive by option, and at most one is set.
  localGatewayKey =
    config.MODULES.services.omniroute.enable
    && (cfg.apiKeySecret != null || cfg.apiKeyFile != null);
in {
  options.MODULES.services.open-webui = {
    enable = mkOption {
      type = types.bool;
      default = config.MODULES.services.omniroute.enable;
      defaultText = lib.literalExpression "config.MODULES.services.omniroute.enable";
      description = ''
        Whether to run Open WebUI, the browser front end for the LLM stack. Defaults to on
        wherever the OmniRoute gateway is enabled, since the gateway by itself only answers
        HTTP - the chat UI is what makes it usable from a phone or another machine. Set to
        `false` to keep the gateway headless, or `true` on a host with no gateway of its own
        (see `openaiUrl`). (Followed litellm.enable until phase 3, 2026-11-09.)
      '';
    };

    apiKeySecret = mkOption {
      type = types.nullOr types.str;
      default = "omniroute_api_key";
      description = ''
        sops secret holding the OmniRoute inference key the UI authenticates with
        (replaced litellm's master key at phase 3). null leaves the placeholder key in
        place - fine only against a gateway that accepts it. IGNORED when `apiKeyFile`
        is set (audit #7, 2026-11-14: the minted per-service key wins, and the sops
        mount is dropped - the UI no longer decrypts the fleet-wide credential).
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = lib.literalExpression "config.MODULES.services.omniroute.keys.openWebui.envFilePath";
      description = ''
        Path to a dotenv file holding the OmniRoute inference key as an
        `OPENAI_API_KEY=sk-...` line; on the gateway host this is a nix-minted
        per-service key (MODULES.services.omniroute.keys - audit #7). The file goes
        to the nixpkgs module as `environmentFile`, which systemd parses root-side at
        every start - a re-minted value lands on a plain restart, and the UI process
        never needs to read the keys dir. null (default) = the apiKeySecret sops
        behavior, unchanged for non-gateway hosts.
      '';
    };

    openaiUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString config.PORTS.omniroute}/v1";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.PORTS.omniroute}/v1"'';
      example = "http://100.64.0.1:8102/v1";
      description = ''
        Which OpenAI-compatible endpoint Open WebUI talks to - the OmniRoute gateway,
        which fans a request out to whichever upstream holds the requested model.
        Defaults to this host's own; point it at another node's Tailscale address to run
        the UI on a machine that has no gateway of its own. Note this only seeds the value
        on first start - it is one of Open WebUI's "PersistentConfig" settings, so it is
        copied into the app's own database on first run and the stored copy wins from then
        on; later changes belong in Admin Settings -> Connections.
      '';
    };

    openaiKey = mkOption {
      type = types.str;
      default = "unused";
      description = ''
        API key sent to `openaiUrl` unless `apiKeySecret` hands over a real one (which
        it does by default on a gateway host - the sops EnvironmentFile overrides this).
        OmniRoute rejects any request without a valid inference key, so the placeholder
        only fits a keyless gateway. Seeded on first start only, same PersistentConfig
        caveat as `openaiUrl` - and it does land in the world-readable Nix store, so a
        real key belongs in the environmentFile rather than here.
      '';
    };
  };

  config = mkIf cfg.enable {
    # nixpkgs 6f06d20 (lock bump 2026-10-30) ships python3Packages.fpdf2 2.8.9 with a test
    # that fails on its own fixtures: test_full_page_image.py::test_image_with_explicit_dimensions
    # compares the MD5 of a rendered SVG page and gets 6732d6d8b5c10606bbcda99fc822c94c where
    # the fixture expects c7b6e70b4b6b72d1b464c65... - measured IDENTICAL on hp, on the r4unb02
    # remote builder, and on hp again with builders disabled (three runs, same hash), and
    # cache.nixos.org has no binary for the rev, i.e. upstream CI never produced one either.
    # Packaging drift in fpdf2's rendering deps, not an fpdf2 bug we can fix from here: the
    # whole open-webui build (and with it hp's system-units/etc/toplevel) deadlocks on it.
    # Skip fpdf2's own test suite; it is open-webui's PDF-export dependency, and its QA is
    # upstream's job. Drop this override the day a lock bump's fpdf2 is cached again.
    nixpkgs.overlays = [
      (final: prev: {
        python3Packages = prev.python3Packages.overrideScope (
          self: super: {
            fpdf2 = super.fpdf2.overridePythonAttrs (old: {
              doCheck = false;
            });
          }
        );
      })
    ];

    # A gateway on this host rejects the "unused" placeholder, so the real key
    # is handed over instead - either minted (audit #7: the keys.<n>.envFilePath dotenv
    # twin, systemd parses it root-side at every start, so a re-mint needs only a restart)
    # or from sops (the old path, kept for hosts without the gateway's mint unit).
    # systemd lets EnvironmentFile override Environment=, so this wins over `openaiKey`
    # without touching the store. Still a PersistentConfig seed: an install that already
    # started once keeps its stored key until it is changed under Admin Settings ->
    # Connections.
    # Declare the mount (hermes-agent's pattern): a bare `{}` contributes only
    # defaults, so it merges with the harness modules' explicit owner/group for
    # the same sops name wherever they co-exist. The service never reads the
    # mount itself - systemd parses EnvironmentFile as root before dropping to
    # the DynamicUser, and the substituted template is what carries the key.
    sops.secrets = mkIf (localGatewayKey && cfg.apiKeyFile == null) {
      ${cfg.apiKeySecret} = {};
    };

    sops.templates."open-webui.env" = mkIf (localGatewayKey && cfg.apiKeyFile == null) {
      content = ''
        OPENAI_API_KEY=${config.sops.placeholder.${cfg.apiKeySecret}}
      '';
      restartUnits = ["open-webui.service"];
    };

    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = config.PORTS.openWebui;
      environmentFile =
        if cfg.apiKeyFile != null
        then cfg.apiKeyFile
        else mkIf localGatewayKey config.sops.templates."open-webui.env".path;

      environment = {
        # The upstream module's own defaults, repeated verbatim: defining `environment` at all
        # replaces its default attrset wholesale rather than merging into it, and dropping these
        # would silently switch the telemetry/analytics phone-home back on.
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";

        OPENAI_API_BASE_URL = cfg.openaiUrl;
        OPENAI_API_KEY = cfg.openaiKey;

        # The stack speaks the OpenAI protocol now, so this is the connection that matters and
        # it has to be on - pointed at the gateway on loopback rather than at api.openai.com.
        # The ollama connection is switched off in the same breath: it is enabled by default and
        # every model-list refresh would otherwise block on a port nothing listens on any more.
        # (PersistentConfig, same first-run caveat as OPENAI_API_BASE_URL.)
        ENABLE_OPENAI_API = "True";
        ENABLE_OLLAMA_API = "False";

        # Absolute links the app hands out (share URLs, notification mails) are built from this.
        # The module's default is http://localhost:<port>, which is only correct for a browser
        # running on this machine - everyone else arrives over the Traefik name below.
        WEBUI_URL = config.MODULES.networking.traefik.urlOf "open-webui";
      };
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.open-webui = "127.0.0.1:${toString config.PORTS.openWebui}";

    # There's nothing to provision account-wise: the first account to sign up becomes the admin,
    # and later signups sit in "pending" until that admin approves them.

    # Ordering only, not a dependency: the UI starts fine without the gateway and retries, but
    # if both come up at boot it would otherwise render an empty model list until the first
    # manual refresh. `wants` is deliberately absent - omniroute.service is already wantedBy
    # multi-user. This orders against the gateway, not against the backends: the servers behind it
    # are on-demand and deliberately not running until someone asks for a model.
    # audit #7: when the key is a minted environmentFile=, the minter must run first - on a
    # wiped-dataset first boot the file only exists after the gateway came up, and systemd
    # fails a start whose EnvironmentFile= is missing. Inert elsewhere: After= against a
    # unit that does not exist is a no-op.
    systemd.services.open-webui.after =
      lib.optionals config.MODULES.services.omniroute.enable ["omniroute.service"]
      ++ lib.optionals (cfg.apiKeyFile != null) ["omniroute-seed-providers.service"];
  };
}
