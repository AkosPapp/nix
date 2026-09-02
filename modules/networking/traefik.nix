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

    path_routes = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Mapping of URL patterns to backend URLs.";
    };

    pass_host_header = mkOption {
      type = types.attrsOf types.bool;
      default = {};
      description = ''
        Per-path override of whether the client's Host header reaches the backend (Traefik's
        default) or is replaced by the backend's own host:port. Set a path to `false` when its
        backend validates the Host header and rejects the public name - ollama, for one, answers
        403 to any Host that isn't loopback or the machine's own hostname.
      '';
    };

    favicon = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Backend URL, path included, to answer the site-wide /favicon.ico with. Every app here
        lives on one shared origin, so any page that declares no `<link rel="icon">` of its own -
        Firefly III's login and register pages, for two - sends the browser to /favicon.ico at
        the root. No path route claims that, so it otherwise falls through to the catch-all and
        comes back 502 on every one of those page loads. Null leaves it doing exactly that.
      '';
      example = "http://127.0.0.1:8082/homepage.ico";
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
      "/traefik" = "http://127.0.0.1:${toString config.PORTS.traefikDashboard}/dashboard";
    };
    services.traefik = {
      enable = true;

      staticConfigOptions = {
        # Entry points configuration
        entryPoints = {
          web = {
            address = ":${toString config.PORTS.traefikHttp}";
            # Traefik is reached through `tailscale serve`, which terminates TLS out on the
            # tailnet and proxies here over loopback, passing the original scheme along in
            # X-Forwarded-Proto. Traefik drops that header as untrusted by default and
            # substitutes its own view of the request - plain http - so backends that build
            # absolute URLs from it (Firefly III, any Laravel app) hand out http:// links that
            # nothing on the tailnet actually serves. Trust the header, but only from loopback:
            # that is exactly the tailscaled hop and nothing else.
            forwardedHeaders.trustedIPs = ["127.0.0.1/32" "::1/128"];
          };
          traefik = {
            address = "127.0.0.1:${toString config.PORTS.traefikDashboard}";
          };
        };

        # Enable API and dashboard
        api = {
          dashboard = true;
          insecure = true;
        };

        experimental.plugins.rewriteHeaders = {
          moduleName = "github.com/bitrvmpd/traefik-plugin-rewrite-headers";
          version = "v0.0.1";
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

        # Split "http://host:port/some/path" into its origin and its path halves. The per-path
        # generators below inline this same parse; these are for the favicon route, which isn't
        # driven by path_routes.
        urlOrigin = url: let
          parts = builtins.split "://" url;
          afterProtocol = builtins.elemAt parts 2;
        in "${builtins.head parts}://${builtins.head (builtins.split "/" afterProtocol)}";

        urlPath = url: let
          afterProtocol = builtins.elemAt (builtins.split "://" url) 2;
        in
          builtins.substring
          (builtins.stringLength (builtins.head (builtins.split "/" afterProtocol)))
          (builtins.stringLength afterProtocol)
          afterProtocol;

        # Site-wide /favicon.ico, served out of whichever backend cfg.favicon names.
        faviconRouter = {
          favicon-router = {
            rule = "Path(`/favicon.ico`)";
            service = "favicon-service";
            middlewares = ["favicon-replacepath"];
            entryPoints = ["web"];
            priority = 200;
          };
        };

        faviconMiddleware = {
          favicon-replacepath.replacePath.path = urlPath cfg.favicon;
        };

        faviconService = {
          favicon-service.loadBalancer.servers = [
            {url = urlOrigin cfg.favicon;}
          ];
        };

        # Generate routers for each path route
        pathRouters = lib.listToAttrs (lib.mapAttrsToList (
            path: backendUrl: let
              routerName = makeRouterName path;
              # Only strip prefix if backend doesn't have a path
              needsStripPrefix = !(hasBackendPath backendUrl);
              hasBackend = hasBackendPath backendUrl;
              middlewares =
                if needsStripPrefix
                then ["${routerName}-stripprefix" "${routerName}-redirect"]
                else if hasBackend
                then ["${routerName}-replacepath" "${routerName}-redirect"]
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
                {
                  name = "${routerName}-redirect";
                  value = {
                    plugin.rewriteHeaders = {
                      rewrites.response = [
                        {
                          header = "Location";
                          regex = "^/(.*)$";
                          replacement = "${path}/$1";
                        }
                        {
                          header = "Location";
                          regex = "^${path}${path}/?(.*)$";
                          replacement = "${path}/$1";
                        }
                      ];
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
                {
                  name = "${routerName}-redirect";
                  value = {
                    plugin.rewriteHeaders = {
                      rewrites.response = [
                        {
                          header = "Location";
                          regex = "^/(.*)$";
                          replacement = "${path}/$1";
                        }
                        {
                          header = "Location";
                          regex = "^${path}${path}/?(.*)$";
                          replacement = "${path}/$1";
                        }
                      ];
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
                loadBalancer =
                  {
                    servers = [
                      {url = baseUrl;}
                    ];
                  }
                  // optionalAttrs (cfg.pass_host_header ? ${path}) {
                    passHostHeader = cfg.pass_host_header.${path};
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
          routers = pathRouters // refererRouters // (optionalAttrs (cfg.defaultPage != null) rootRedirectRouter) // (optionalAttrs (cfg.favicon != null) faviconRouter) // catchAllRouter;
          middlewares = pathMiddlewares // (optionalAttrs (cfg.defaultPage != null) rootRedirectMiddleware) // (optionalAttrs (cfg.favicon != null) faviconMiddleware);
          services = pathServices // notFoundService // (optionalAttrs (cfg.favicon != null) faviconService);
        };
      };
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      config.PORTS.traefikHttp
    ];
  };
}
