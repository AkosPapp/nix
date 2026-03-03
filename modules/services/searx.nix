{
  config,
  pkgs,
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
      MODULES.networking.traefik.path_routes = {
        "/searx" = "http://127.0.0.1:${toString port}";
      };

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

        settings = {
          server = {
            port = port;
            bind_address = "127.0.0.1";
            secret_key = "change_this_to_a_random_secret_key";
            base_url = "https://${config.networking.fqdn}/searx";
          };

          # Basic settings
          general = {
            instance_name = "My Searx Instance";
          };
        };
        domain = "https://${config.networking.fqdn}/searx";

        # Enable local Redis instance for caching
        redisCreateLocally = true;
      };
    }
  );
}
