{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.outline;
  traefik = config.MODULES.networking.traefik;
  idp = config.MODULES.security.idp;

  nginxUrl = "http://127.0.0.1:${toString config.PORTS.outline}";

  # Outline bakes this into the page it serves (window.env.URL, the CSP's script-src/connect-src,
  # the websocket URL, cookie domain, the OIDC callback...) - everything downstream assumes every
  # visitor reaches it at exactly this one origin. It can't be "whichever host the browser used"
  # the way a stateless static site could be, so once public.enable claims a second origin
  # (outline.nix's own Funnel port) that one has to be canonical: it is reachable from the
  # tailnet too, whereas the tailnet subdomain's step-ca certificate isn't trusted by an
  # off-tailnet browser, which is what left a public visitor's page silently hanging - loading a
  # websocket/asset from https://outline.hp that only resolves and is trusted on the tailnet.
  publicOrigin = "https://${config.networking.fqdn}:${toString config.PORTS.outlinePublicFunnel}";
  url =
    if cfg.public.enable
    then publicOrigin
    else traefik.urlOf "outline";
in {
  options.MODULES.services.outline = {
    enable = mkEnableOption ''
      Outline at its own tailnet subdomain (outline.<traefik domain>), and - once public.enable
      is also set - on the internet too. Logins go through the IdP in MODULES.security.idp
      (git.robo4you.at), the same OAuth2 application mdbook.nix uses, once its redirect URI is
      registered there (see RUNBOOK-public.md); until then it falls back to Outline's own
      email/password accounts
    '';

    public.enable = mkEnableOption ''
      Outline on the internet, not just the tailnet. Unlike mdbook.nix's route, this isn't a path
      on Traefik's shared public entry point: Outline has no base-path support (its
      frontend fetches `/api/...`, `/ws` etc from the root unconditionally), so a path prefix
      there would break as soon as the browser's JS made its first same-origin request. Instead
      this claims the third of Tailscale Funnel's three allowed ports (8443 is
      traefikPublicFunnel's) and funnels straight to Outline's own loopback port, so Outline sees
      itself at the root of its own origin either way.
    '';

    url = mkOption {
      type = types.str;
      readOnly = true;
      default = url;
      description = "The one origin Outline is configured to think it's reachable at (see the comment on `url` above) - for other modules (homepage.nix) to link to, instead of guessing.";
    };
  };

  config = mkIf cfg.enable {
    services.outline = {
      enable = true;
      port = config.PORTS.outline;
      publicUrl = url;
      storage.storageType = "local";
      # oidcAuthentication is deliberately left unset: it requires the client ID as a plain
      # string option, baked into the unit's `Environment=` at build time straight from the Nix
      # store, with no file-based variant. The systemd.services block below reimplements the
      # same env vars by hand instead, so both the client ID and secret come from sops at
      # activation time and never touch the store.
    };

    sops.secrets."outline/idp_client_id" = mkIf idp.enabled {
      key = idp.clientIdSecret;
      owner = config.services.outline.user;
      restartUnits = ["outline.service"];
    };
    sops.secrets."outline/idp_client_secret" = mkIf idp.enabled {
      key = idp.clientSecretSecret;
      owner = config.services.outline.user;
      restartUnits = ["outline.service"];
    };
    sops.templates."outline-oidc.env" = mkIf idp.enabled {
      owner = config.services.outline.user;
      content = ''
        OIDC_CLIENT_ID=${config.sops.placeholder."outline/idp_client_id"}
        OIDC_CLIENT_SECRET=${config.sops.placeholder."outline/idp_client_secret"}
      '';
      restartUnits = ["outline.service"];
    };

    systemd.services.outline.serviceConfig.EnvironmentFile = mkIf idp.enabled [config.sops.templates."outline-oidc.env".path];
    systemd.services.outline.environment = mkIf idp.enabled {
      # Forgejo's fixed OIDC endpoints; Outline has no discovery support.
      OIDC_AUTH_URI = "${idp.issuer}/login/oauth/authorize";
      OIDC_TOKEN_URI = "${idp.issuer}/login/oauth/access_token";
      OIDC_USERINFO_URI = "${idp.issuer}/login/oauth/userinfo";
      OIDC_DISPLAY_NAME = "git.robo4you.at";
      OIDC_SCOPES = "openid profile email";
    };

    MODULES.security.idp.redirectUris = ["${url}/auth/oidc.callback"];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.outline = nginxUrl;

    MODULES.networking.tailscale.serve = mkIf cfg.public.enable {
      outline-public = {
        type = "funnel";
        target = nginxUrl;
        httpsPort = config.PORTS.outlinePublicFunnel;
      };
    };
  };
}
