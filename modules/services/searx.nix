{
  config,
  pkgs,
  pkgs-unstable,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.services.searx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable searx search engine";
      };
    };
  };

  config = lib.mkIf config.MODULES.services.searx.enable (
    let
      port = config.PORTS.searx;
    in {
      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.services.searx = "127.0.0.1:${toString port}";

      # # Add custom route for searx static assets containing 'sxng'
      # services.traefik.dynamicConfigOptions.http.routers.searx-static-router = {
      #   rule = "PathPrefix(`/static/`) && PathRegexp(`.*sxng.*`) && !Header(`Referer`, `.+`)";
      #   service = "searx-static-service";
      #   entryPoints = ["web"];
      #   priority = 75;
      # };

      # # Add routes for searx simple theme assets
      # services.traefik.dynamicConfigOptions.http.routers.searx-favicon-router = {
      #   rule = "PathRegexp(`^/static/themes/simple/img/favicon\\..*`) && !Header(`Referer`, `.+`)";
      #   service = "searx-static-service";
      #   entryPoints = ["web"];
      #   priority = 75;
      # };

      # services.traefik.dynamicConfigOptions.http.routers.searx-chunk-router = {
      #   rule = "PathRegexp(`^/static/themes/simple/chunk/.*\\.min\\.js$`) && !Header(`Referer`, `.+`)";
      #   service = "searx-static-service";
      #   entryPoints = ["web"];
      #   priority = 75;
      # };

      # services.traefik.dynamicConfigOptions.http.services.searx-static-service = {
      #   loadBalancer = {
      #     servers = [
      #       {url = "http://127.0.0.1:${toString port}";}
      #     ];
      #   };
      # };

      services.searx = {
        enable = true;
        # Engine scrapers break often; the stable channel's searxng lags unstable by months.
        package = pkgs-unstable.searxng;
        environmentFile = config.sops.templates."searx.env".path;

        settings = {
          server = {
            port = port;
            bind_address = "127.0.0.1";
            secret_key = "$SEARX_SECRET_KEY"; # substituted from environmentFile at start
            base_url = config.MODULES.networking.traefik.urlOf "searx";
            # Only reachable via Traefik on LAN/tailnet; the limiter would just see the proxy IP.
            limiter = false;
          };

          # Enable JSON format for API calls like n8n
          search = {
            formats = [
              "html"
              "json"
            ];
            suspended_times = {
              SearxEngineAccessDenied = 3600;
              SearxEngineCaptcha = 3600;
              SearxEngineTooManyRequests = 600;
            };
          };

          outgoing = {
            request_timeout = 4.0;
            max_request_timeout = 10.0;
          };

          # Merged by name into the default engine list, so no single blocked engine kills results.
          engines = [
            {
              name = "bing";
              disabled = false;
            }
            {
              name = "mojeek";
              disabled = false;
            }
            {
              name = "qwant";
              disabled = false;
            }
            {
              name = "yahoo";
              disabled = false;
            }
          ];

          # Basic settings
          general = {
            instance_name = "My Searx Instance";
          };
        };
        domain = config.MODULES.networking.traefik.urlOf "searx";

        # Enable local Redis instance for caching
        redisCreateLocally = true;
      };

      sops.secrets."searx/secret_key" = {};
      sops.templates."searx.env" = {
        content = ''
          SEARX_SECRET_KEY=${config.sops.placeholder."searx/secret_key"}
        '';
        restartUnits = ["searx-init.service" "searx.service"];
      };
    }
  );
}
