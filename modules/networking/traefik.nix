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
      default = 80;
      description = "HTTP port for Traefik";
    };

    dashboardPort = mkOption {
      type = types.int;
      default = 8888;
      description = "Port for Traefik dashboard";
    };

    path_routes = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Mapping of URL patterns to backend URLs.";
    };
  };

  config = mkIf cfg.enable {
    MODULES.networking.tailscale.serve.traefik.target = "http://127.0.0.1:80";
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

      dynamicConfigOptions = let
        # Generate router name from path by removing slashes and special chars
        makeRouterName = path: builtins.replaceStrings ["/"] ["-"] (builtins.substring 1 (builtins.stringLength path) path);

        # Parse backend URL to check if it has a path component
        hasBackendPath = backendUrl: let
          # Extract everything after the first three slashes (protocol://)
          afterProtocol =
            builtins.substring 0 (builtins.stringLength backendUrl)
            (builtins.elemAt (builtins.split "://" backendUrl) 2);
          # Check if there's a slash after the host:port
          parts = builtins.split "/" afterProtocol;
        in
          (builtins.length parts) > 1;

        # Generate routers for each path route
        pathRouters = lib.listToAttrs (lib.mapAttrsToList (
            path: backendUrl: let
              routerName = makeRouterName path;
              # Only strip prefix if backend doesn't have a path
              needsStripPrefix = !(hasBackendPath backendUrl);
              middlewares =
                if needsStripPrefix
                then ["${routerName}-stripprefix"]
                else [];
            in {
              name = "${routerName}-router";
              value = {
                rule = "(Path(`${path}`) || PathPrefix(`${path}/`))";
                service = "${routerName}-service";
                entryPoints = ["web"];
                middlewares = middlewares;
                priority = 100;
              };
            }
          )
          cfg.path_routes);

        # Generate referer-based routers for assets
        refererRouters = lib.listToAttrs (lib.mapAttrsToList (
            path: backendUrl: let
              routerName = makeRouterName path;
            in {
              name = "${routerName}-referer-router";
              value = {
                rule = "PathPrefix(`/`) && HeaderRegexp(`Referer`, `.*${path}.*`)";
                service = "${routerName}-service";
                entryPoints = ["web"];
                priority = 50;
              };
            }
          )
          cfg.path_routes);

        # Catch-all router for 404
        catchAllRouter = {
          catch-all-router = {
            rule = "PathPrefix(`/`)";
            service = "not-found-service";
            entryPoints = ["web"];
            priority = 1;
          };
        };

        # Generate middlewares for each path (only if needed)
        pathMiddlewares = lib.listToAttrs (lib.flatten (lib.mapAttrsToList (
            path: backendUrl: let
              routerName = makeRouterName path;
              needsStripPrefix = !(hasBackendPath backendUrl);
            in
              if needsStripPrefix
              then [
                {
                  name = "${routerName}-stripprefix";
                  value = {
                    stripPrefix = {
                      prefixes = [path];
                    };
                  };
                }
              ]
              else []
          )
          cfg.path_routes));

        # Generate services for each backend
        pathServices = lib.listToAttrs (lib.mapAttrsToList (
            path: backendUrl: let
              routerName = makeRouterName path;
            in {
              name = "${routerName}-service";
              value = {
                loadBalancer = {
                  servers = [
                    {url = backendUrl;}
                  ];
                };
              };
            }
          )
          cfg.path_routes);

        notFoundService = {
          not-found-service = {
            loadBalancer = {
              servers = [
                {url = "http://127.0.0.1:1";}
              ];
            };
          };
        };
      in {
        http = {
          routers = pathRouters // refererRouters // catchAllRouter;
          middlewares = pathMiddlewares;
          services = pathServices // notFoundService;
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
