{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.services.i2pd.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable i2pd I2P router";
    };
  };

  config = lib.mkIf config.MODULES.services.i2pd.enable {
    services.i2pd = {
      enable = true;
      address = "0.0.0.0";
      port = config.PORTS.i2pdRouter;
      bandwidth = 1024; # L = 32KB/s, O = 256KB/s, P = unlimited — adjust to taste
      upnp.enable = true;
      nat = true;
      yggdrasil.enable = true;

      # WebUI accessible over Tailscale
      proto.http = {
        enable = true;
        address = "127.0.0.1";
        port = config.PORTS.i2pdWebui;
        hostname = config.networking.fqdn;
      };

      # Optional but recommended: SAM API for apps that use i2p
      proto.sam = {
        enable = true;
        address = "127.0.0.1";
        port = config.PORTS.i2pdSam;
      };

      proto.httpProxy = {
        enable = true;
        address = config.MODULES.networking.tailscale.hostIP;
        port = config.PORTS.i2pdHttpProxy;
      };

      proto.socksProxy = {
        enable = true;
        address = config.MODULES.networking.tailscale.hostIP;
        port = config.PORTS.i2pdSocksProxy;
      };
    };

    # Allow the WebUI port through the firewall on tailscale0
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [config.PORTS.i2pdWebui];
    networking.firewall.allowedTCPPorts = [config.PORTS.i2pdRouter];
    networking.firewall.allowedUDPPorts = [config.PORTS.i2pdRouter];

    # Yggdrasil mesh network (used by i2pd for additional reachability)
    services.yggdrasil = {
      enable = true;
      persistentKeys = true;
      settings = {
        IfName = "yggdrasil";
        Peers = [
          "tls://ygg7.mk16.de:1338?key=000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae"
          "tls://109.176.250.101:65534"
          "quic://94.159.111.184:65535"
        ];
        Listen = [];
      };
    };
    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.path_routes = {
      "/i2pd" = "http://127.0.0.1:${toString config.PORTS.i2pdWebui}";
    };

    # Redirect /?page=commands → /i2pd?page=commands when Referer is /i2pd/i2pd
    services.traefik.dynamicConfigOptions = let
      fqdn = config.networking.fqdn;
      fqdnEscaped = builtins.replaceStrings ["."] ["\\."] fqdn;
    in {
      http = {
        routers = {
          i2pd-redirect = {
            rule = "Host(`${fqdn}`) && Path(`/`) && HeaderRegexp(`Referer`, `^https://${fqdnEscaped}/i2pd.*`)";
            entryPoints = ["web"];
            middlewares = ["redirect-i2pd"];
            service = "i2pd-noop";
            priority = 1000;
          };
        };
        services = {
          i2pd-noop = {
            loadBalancer = {
              servers = [{url = "http://127.0.0.1:1";}];
            };
          };
        };
        middlewares = {
          redirect-i2pd = {
            redirectRegex = {
              regex = "^https?://[^/]*/(.*)$";
              replacement = "https://${fqdn}/i2pd/$1";
              #replacement = "1.1.1.1";
              permanent = false;
            };
          };
        };
      };
    };
  };
}
