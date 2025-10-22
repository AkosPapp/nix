{
  config,
  lib,
  ...
}: let
  tailscaleIp = config.MODULES.networking.tailscale.hostIP;
in {
  options = {
    MODULES.networking.traefik.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Traefik reverse proxy on Tailscale IP.";
    };
  };

  config = lib.mkIf config.MODULES.networking.traefik.enable {
    MODULES.networking.tailscale.hostAliases = ["api"];

    services.traefik = {
      enable = true;
      staticConfigOptions = {
        entryPoints = {
          web = {
            address = "${tailscaleIp}:80";
            http.redirections.entryPoint = {
              to = "websecure";
              scheme = "https";
            };
          };
          websecure = {
            address = "${tailscaleIp}:443";
          };
          dashboard = {
            address = "${tailscaleIp}:8080";
          };
        };
        certificatesResolvers.myresolver.tailscale = {};
        api.dashboard = true;
        log.level = "DEBUG";
      };
      dynamicConfigOptions = {
        http = {
          routers = {
            dashboard = {
              entryPoints = ["dashboard"];
              rule = "PathPrefix(`/`)";
              service = "api@internal";
              tls.certResolver = "myresolver";
            };
            api-fqdn = {
              entryPoints = ["websecure"];
              rule = "Host(`api.${config.networking.fqdn}`) && PathPrefix(`/`)";
              service = "api@internal";
              tls.certResolver = "myresolver";
            };
          };
        };
      };
    };

    # Open firewall only on Tailscale IP (requires nftables or similar, not NixOS default firewall)
    networking.firewall = {
      enable = true;
      # No global allowedTCPPorts!
      # Use extraInputRules to allow only from Tailscale interface/IP
      extraInputRules = ''
        ip saddr ${tailscaleIp} tcp dport {80,443,8080} accept comment "Allow Traefik only from Tailscale IP"
      '';
    };
  };
}
