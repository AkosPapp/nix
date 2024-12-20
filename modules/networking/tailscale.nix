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
      extraSetFlags = ["--accept-dns=false"];
      package = pkgs-unstable.tailscale;
    };
    networking.firewall.checkReversePath = "loose";
    MODULES.networking.dnsmasq.enable = true;
  };
}
