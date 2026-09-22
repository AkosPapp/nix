{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;

  cfg = config.MODULES.services.open-webui;

  localGatewayKey =
    config.MODULES.services.litellm.enable
    && config.MODULES.services.litellm.masterKeySecret != null;
in {
  options.MODULES.services.open-webui = {
    enable = mkOption {
      type = types.bool;
      default = config.MODULES.services.litellm.enable;
      defaultText = lib.literalExpression "config.MODULES.services.litellm.enable";
      description = ''
        Whether to run Open WebUI, the browser front end for the LLM stack. Defaults to on
        wherever the LiteLLM gateway is enabled, since LiteLLM by itself only answers HTTP - the
        chat UI is what makes it usable from a phone or another machine. Set to `false` to keep
        the gateway headless, or `true` on a host with no gateway of its own (see `openaiUrl`).
      '';
    };

    openaiUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString config.PORTS.litellm}/v1";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.PORTS.litellm}/v1"'';
      example = "http://100.64.0.1:8095/v1";
      description = ''
        Which OpenAI-compatible endpoint Open WebUI talks to - the LiteLLM gateway, which is
        what fans a request out to whichever host holds the requested model. Defaults to this
        host's own; point it at another node's Tailscale address to run the UI on a machine that
        has no gateway of its own. Note this only seeds the value on first start - it is one of
        Open WebUI's "PersistentConfig" settings, so it is copied into the app's own database on
        first run and the stored copy wins from then on; later changes belong in Admin Settings
        -> Connections.
      '';
    };

    openaiKey = mkOption {
      type = types.str;
      default = "unused";
      description = ''
        API key sent to `openaiUrl`. LiteLLM only checks this once it has been given a master
        key, so the placeholder is right for the common loopback case; set it to that master key
        on a host where the gateway is authenticated. Seeded on first start only, same
        PersistentConfig caveat as `openaiUrl` - and it does land in the world-readable Nix
        store, so a real key belongs in the gateway's own environmentFile rather than here.
      '';
    };
  };

  config = mkIf cfg.enable {
    # A gateway on this host with a master key rejects the "unused" placeholder, so the real key
    # is handed over from sops instead. systemd lets EnvironmentFile override Environment=, so
    # this wins over `openaiKey` without touching the store. Still a PersistentConfig seed: an
    # install that already started once keeps its stored key until it is changed under Admin
    # Settings -> Connections.
    sops.templates."open-webui.env" = mkIf localGatewayKey {
      content = ''
        OPENAI_API_KEY=${config.sops.placeholder.${config.MODULES.services.litellm.masterKeySecret}}
      '';
      restartUnits = ["open-webui.service"];
    };

    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = config.PORTS.openWebui;
      environmentFile = mkIf localGatewayKey config.sops.templates."open-webui.env".path;

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
        # it has to be on - pointed at LiteLLM on loopback rather than at api.openai.com. The
        # ollama connection is switched off in the same breath: it is enabled by default and
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
    # manual refresh. `wants` is deliberately absent - litellm.service is already wantedBy
    # multi-user. This orders against the gateway, not against vLLM: the servers behind it are
    # socket-activated and deliberately not running until someone asks for a model.
    systemd.services.open-webui.after = lib.optional config.MODULES.services.litellm.enable "litellm.service";
  };
}
