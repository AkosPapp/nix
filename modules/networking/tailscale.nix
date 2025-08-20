{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Tailscale VPN";
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable {
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = ["--accept-dns=false" "--accept-routes=true"];
      package = pkgs-unstable.tailscale;
    };
    networking.firewall.checkReversePath = "loose";
    networking.hosts = {
      "100.125.194.29" = ["legion5"];
      "100.127.104.86" = ["hp"];
      "100.97.77.48" = ["phone"];
    };
    MODULES.networking.dnsmasq.enable = false;
  };
}
