{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.MODULES.security.idp;
in {
  options.MODULES.security.idp = {
    issuer = mkOption {
      type = types.str;
      default = "https://git.robo4you.at";
      description = ''
        OIDC issuer the web apps (mdbook.nix, outline.nix) log people in with, i.e. who
        counts as "a robo4you account". The default is the robo4you Forgejo: unlike the Keycloak
        at idp.robo4you.at (where clients need a realm admin), any Forgejo user can register an
        OAuth2 application, and Forgejo is a full OIDC provider (RS256 ID tokens, a `groups`
        claim with org and org:team memberships).
      '';
    };

    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether the OAuth2 application exists (on Forgejo: Settings, Applications, Manage OAuth2
        applications - confidential, with every redirect URI listed in `redirectUris`) and its ID
        and secret are in sops. Until then, the apps that depend on it stay tailnet-only.
      '';
    };

    clientIdSecret = mkOption {
      type = types.str;
      default = "idp/client_id";
      description = "sops secret holding the client ID (not secret as such, but kept next to the secret).";
    };

    clientSecretSecret = mkOption {
      type = types.str;
      default = "idp/client_secret";
      description = "sops secret holding that client's secret.";
    };

    redirectUris = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Redirect URIs the apps on this host need registered on the client. Filled in by the
        modules that use the IdP; listed in the runbook.
      '';
    };

    enabled = mkOption {
      type = types.bool;
      readOnly = true;
      default = cfg.enable;
      description = "Alias of `enable`, for the modules that consume the IdP.";
    };
  };
}
