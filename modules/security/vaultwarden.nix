{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.security.vaultwarden.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SOPS";
    };
  };

  config = lib.mkIf config.MODULES.security.vaultwarden.enable {
    services.vaultwarden = {
      enable = true;
      webVaultPackage = pkgs-unstable.vaultwarden.webvault;
      package = pkgs-unstable.vaultwarden;

      config = {
        DOMAIN = "https://akos01.tail546fb.ts.net/vaultwarden";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222; # any non-conflicting port
        ROCKET_WORKERS = 4;
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = false;
        WEBSOCKET_ENABLED = true;
        ADMIN_TOKEN = "$argon2id$v=19$m=65540,t=3,p=4$7g+kVALpbIc0zrAr81ymVHqerryGwYngi0w+/pJPHGk$tuAopZ5yBhpqgFfz/KRm46RWSzGjHToQvgFEnhppJIQ";
        ROCKET_LOG = "INFO";
      };
    };
    # tailscale serve --set-path vaultwarden http://localhost:8222

    # Optional: Bitwarden directory connector (if using LDAP/AD)
    #services.bitwarden-directory-connector-cli.domain = "akos01.tail546fb.ts.net";

    MODULES.networking.tailscale.hostAliases = ["vaultwarden"];
  };
}
