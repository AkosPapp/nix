{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.networking.searx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable reverse proxy services.";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 8081;
        description = "The port to listen on.";
      };
    };
  };

  config = lib.mkIf config.MODULES.networking.searx.enable (
    let
      port = config.MODULES.networking.searx.port;
    in {
      services.searx = {
        enable = true;

        settings = {
          server = {
            port = port;
            bind_address = "0.0.0.0";
            secret_key = "change_this_to_a_random_secret_key";
          };

          # Basic settings
          general = {
            instance_name = "My Searx Instance";
          };
        };

        # Enable local Redis instance for caching
        redisCreateLocally = true;
      };

      # Open firewall if needed
      networking.firewall.allowedTCPPorts = [port];
    }
  );
}
