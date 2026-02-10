{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.MODULES.networking.traefik;
in {
  options.MODULES.networking.traefik = {
    enable = mkEnableOption "Traefik reverse proxy";

    httpPort = mkOption {
      type = types.int;
      default = 888;
      description = "HTTP port for Traefik";
    };

    dashboardPort = mkOption {
      type = types.int;
      default = 889;
      description = "Port for Traefik dashboard";
    };
  };

  config = mkIf cfg.enable {
    services.traefik = {
      enable = true;

      staticConfigOptions = {
        # Entry points configuration
        entryPoints = {
          web = {
            address = ":${toString cfg.httpPort}";
          };
          traefik = {
            address = ":${toString cfg.dashboardPort}";
          };
        };

        # Enable API and dashboard
        api = {
          dashboard = true;
          insecure = true;
        };

        # Logging
        log = {
          level = "INFO";
        };

        accessLog = {};
      };

      dynamicConfigOptions = {
        http = {
          routers = {
            nix-router = {
              rule = "(Path(`/nix`) || PathPrefix(`/nix/`))";
              service = "nix-service";
              entryPoints = ["web"];
              middlewares = ["nix-stripprefix"];
              priority = 100;
            };
            assets-router = {
              rule = "PathPrefix(`/`)";
              service = "nix-service";
              entryPoints = ["web"];
              priority = 1;
            };
          };

          middlewares = {
            nix-stripprefix = {
              stripPrefix = {
                prefixes = ["/nix"];
              };
            };
          };

          services = {
            nix-service = {
              loadBalancer = {
                servers = [
                  {url = "http://127.0.0.1:8085";}
                ];
              };
            };
          };
        };
      };
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      cfg.httpPort
      cfg.dashboardPort
    ];
  };
}
