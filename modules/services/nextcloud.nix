{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.nextcloud;
in {
  options.MODULES.services.nextcloud = {
    enable = mkEnableOption "Nextcloud";

    hostName = mkOption {
      type = types.str;
      default = "nextcloud.example.com";
      description = "Nginx virtual host used by Nextcloud";
    };

    adminUser = mkOption {
      type = types.str;
      default = "admin";
      description = "Initial Nextcloud admin username";
    };
  };

  config = mkIf cfg.enable {
    sops.secrets."nextcloud/admin-pass" = {
      owner = "nextcloud";
      mode = "0400";
    };

    services.nextcloud = {
      enable = true;
      hostName = cfg.hostName;
      https = false;
      configureRedis = true;
      database.createLocally = true;

      config = {
        dbtype = "pgsql";
        adminuser = cfg.adminUser;
        adminpassFile = config.sops.secrets."nextcloud/admin-pass".path;
      };

      settings = {
        overwriteprotocol = "https";
        overwritehost = config.MODULES.networking.traefik.hostOf "nextcloud";
        trusted_domains = [
          cfg.hostName
          (config.MODULES.networking.traefik.hostOf "nextcloud")
          "localhost"
          "127.0.0.1"
        ];
        trusted_proxies = ["127.0.0.1"];
      };
    };

    services.nginx.enable = true;
    services.nginx.virtualHosts.${cfg.hostName} = {
      listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.nextcloud;
        }
      ];
      forceSSL = false;
      enableACME = false;
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.nextcloud = "127.0.0.1:${toString config.PORTS.nextcloud}";
  };
}
