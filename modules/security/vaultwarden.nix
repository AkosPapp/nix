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

      #dbBackend = "sqlite"; # or "postgresql" if you run a Postgres service
      #backupDir = "/var/backup/vaultwarden";
      #environmentFile = "/etc/vaultwarden/env"; # create this manually (permissions 600)

      config = {
        DOMAIN = "https://akos01.tail546fb.ts.net/";
        #ROCKET_ADDRESS = "100.71.138.61";
        ROCKET_ADDRESS = "0.0.0.0";
        ROCKET_PORT = 8222; # any non-conflicting port
        ROCKET_WORKERS = 4;
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = true;
        WEBSOCKET_ENABLED = true;
        ADMIN_TOKEN = "$argon2id$v=19$m=65540,t=3,p=4$iijDzhVSrkmcBuMy1/zhTmxCk91+sDSpa1HSttlVa80$UeyCHCs9voPqlIT/GCSkF0H79WrRJ/CuhrOZlQyYDYA"; # or set via env file
        ROCKET_LOG = "TRACE";
      };
    };
    # tailscale serve --set-path vaultwarden http://localhost:8222

    # Optional: Bitwarden directory connector (if using LDAP/AD)
    #services.bitwarden-directory-connector-cli.domain = "akos01.tail546fb.ts.net";

    # Network hardening: Only allow Tailscale and local access
    networking.firewall = {
      #allowedTCPPorts = [8222]; # none globally
      #interfaces."tailscale0".allowedTCPPorts = [8222];
    };

    # Tailscale service
    services.tailscale.enable = true;

    # Example environment file (/etc/vaultwarden/env)
    # (Do NOT check this into version control)
    #
    # ADMIN_TOKEN=supersecureadmintoken123
    # DATABASE_URL=data/db.sqlite3
    # SMTP_HOST=smtp.example.com
    # SMTP_FROM=vault@yourdomain.com
    # SMTP_USERNAME=vault@yourdomain.com
    # SMTP_PASSWORD=yourpassword
    #
  };
}
