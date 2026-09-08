{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;

  cfg = config.MODULES.services.open-webui;
in {
  options.MODULES.services.open-webui = {
    enable = mkOption {
      type = types.bool;
      default = config.MODULES.services.ollama.enable;
      defaultText = lib.literalExpression "config.MODULES.services.ollama.enable";
      description = ''
        Whether to run Open WebUI, the browser front end for ollama. Defaults to on wherever
        ollama is enabled, since ollama by itself only answers HTTP and a local `ollama run` -
        the chat UI is what makes it usable from a phone or another machine. Set to `false` to
        keep ollama headless, or `true` on a host with no local LLM server (see `ollamaUrl`).
      '';
    };

    ollamaUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString config.PORTS.ollama}";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.PORTS.ollama}"'';
      example = "http://100.64.0.1:11434";
      description = ''
        Which ollama Open WebUI talks to. Defaults to this host's own; point it at another
        node's Tailscale address to run the UI on a machine that has no LLM server (or no GPU)
        of its own. Note this only seeds the value on first start - it is one of Open WebUI's
        "PersistentConfig" settings, so it is copied into the app's own database on first run
        and the stored copy wins from then on; later changes belong in Admin Settings ->
        Connections.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = config.PORTS.openWebui;

      environment = {
        # The upstream module's own defaults, repeated verbatim: defining `environment` at all
        # replaces its default attrset wholesale rather than merging into it, and dropping these
        # would silently switch the telemetry/analytics phone-home back on.
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";

        OLLAMA_BASE_URL = cfg.ollamaUrl;

        # No host here has an OpenAI key, but the OpenAI connection is enabled by default, and
        # every model-list refresh then blocks on api.openai.com timing out before the local
        # ollama models appear. (PersistentConfig, same first-run caveat as OLLAMA_BASE_URL.)
        ENABLE_OPENAI_API = "False";

        # Absolute links the app hands out (share URLs, notification mails) are built from this.
        # The module's default is http://localhost:<port>, which is only correct for a browser
        # running on this machine - everyone else arrives over the Tailscale name below.
        WEBUI_URL = "https://${config.networking.fqdn}:${toString config.PORTS.openWebui}";
      };
    };

    # Open WebUI serves its SPA, API and socket.io from the origin root and exposes no
    # root_path/base-path setting, so unlike almost everything else here it can't be mounted
    # under a Traefik subpath: the browser asks for /_app/... and /static/... at the shared
    # origin's root and gets the catch-all, and its client-side routing rewrites the address bar
    # to root-absolute paths on top of that. So it gets an origin of its own - tailscale serve
    # terminates TLS on the app's own port and proxies straight to it, with no reverse proxy in
    # between. Immich is here for the same reason.
    MODULES.networking.tailscale.serve.open-webui = {
      target = "http://127.0.0.1:${toString config.PORTS.openWebui}";
      httpsPort = config.PORTS.openWebui;
    };

    # There's nothing to provision account-wise: the first account to sign up becomes the admin,
    # and later signups sit in "pending" until that admin approves them.

    # Ordering only, not a dependency: the UI starts fine without ollama and retries, but if
    # both come up at boot it would otherwise render an empty model list until the first manual
    # refresh. `wants` is deliberately absent - ollama.service is already wantedBy multi-user.
    systemd.services.open-webui.after = lib.optional config.MODULES.services.ollama.enable "ollama.service";
  };
}
