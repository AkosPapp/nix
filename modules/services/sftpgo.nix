{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.services.sftpgo.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SFTPGo server for WebDAV access.";
    };
  };

  config = lib.mkMerge [
    (
      lib.mkIf
      config.MODULES.services.sftpgo.enable
      {
        services.sftpgo = {
          enable = true;

          settings = {
            # Data directory
            data_provider = {
              driver = "sqlite";
              name = "/var/lib/sftpgo/sftpgo.db";
            };

            # WebDAV configuration
            webdavd = {
              bindings = [
                {
                  port = config.PORTS.sftpgoWebdav;
                  address = "127.0.0.1";
                  enable_https = false;
                }
              ];
            };

            # Admin UI (optional but useful)
            httpd = {
              web_root = "/sftpgo";
              bindings = [
                {
                  port = config.PORTS.sftpgoHttp;
                  address = "127.0.0.1";
                }
              ];
            };

            # Optional: Disable other protocols if you only want WebDAV
            sftpd.bindings = [];
            ftpd.bindings = [];
          };
        };

        MODULES.networking.traefik.enable = true;
        MODULES.networking.traefik.path_routes = {
          "/sftpgo" = "http://127.0.0.1:${toString config.PORTS.sftpgoHttp}/sftpgo";
          "/webdav" = "http://127.0.0.1:${toString config.PORTS.sftpgoWebdav}";
        };
      }
    )
  ];
}
