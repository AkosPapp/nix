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

    defaultPage = mkOption {
      type = types.nullOr types.str;
      default = "/homepage";
      description = "Default page to redirect to when accessing root path. Set to null to disable redirect.";
    };
  };

  config = mkIf cfg.enable {
    MODULES.networking.tailscale.serve.traefik.target = "http://127.0.0.1:80";
    MODULES.networking.traefik.path_routes = {
      "/traefik" = "http://127.0.0.1:${toString cfg.dashboardPort}/dashboard";
    };
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
              hasBackend = hasBackendPath backendUrl;
              middlewares =
                if needsStripPrefix
                then ["${routerName}-stripprefix"]
                else if hasBackend
                then ["${routerName}-replacepath"]
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

        # Root path redirect to default page (if configured)
        rootRedirectRouter = {
          root-redirect-router = {
            rule = "Path(`/`)";
            middlewares = ["root-redirect-middleware"];
            service = "noop@internal";
            entryPoints = ["web"];
            priority = 200;
          };
        };

        rootRedirectMiddleware = {
          root-redirect-middleware = {
            redirectRegex = {
              regex = "^.*$";
              replacement = cfg.defaultPage;
              permanent = false;
            };
          };
        };

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
              # Extract backend path if it exists
              backendPath =
                if hasBackendPath backendUrl
                then let
                  afterProtocol = builtins.elemAt (builtins.split "://" backendUrl) 2;
                  pathPart =
                    builtins.substring
                    (builtins.stringLength (builtins.head (builtins.split "/" afterProtocol)))
                    (builtins.stringLength afterProtocol)
                    afterProtocol;
                in
                  pathPart
                else "";
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
              else if backendPath != ""
              then [
                {
                  name = "${routerName}-replacepath";
                  value = {
                    replacePathRegex = {
                      regex = "^${path}(/.*)?$";
                      replacement = "${backendPath}$1";
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
              # Strip path from backend URL for the service
              baseUrl =
                if hasBackendPath backendUrl
                then let
                  parts = builtins.split "://" backendUrl;
                  protocol = builtins.head parts;
                  afterProtocol = builtins.elemAt parts 2;
                  hostPort = builtins.head (builtins.split "/" afterProtocol);
                in "${protocol}://${hostPort}"
                else backendUrl;
            in {
              name = "${routerName}-service";
              value = {
                loadBalancer = {
                  servers = [
                    {url = baseUrl;}
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
          routers = pathRouters // refererRouters // (optionalAttrs (cfg.defaultPage != null) rootRedirectRouter) // catchAllRouter;
          middlewares = pathMiddlewares // (optionalAttrs (cfg.defaultPage != null) rootRedirectMiddleware);
          services = pathServices // notFoundService;
        };
      };
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      cfg.httpPort
    ];
  };
}
