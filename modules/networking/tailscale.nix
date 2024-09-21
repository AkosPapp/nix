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
      package = pkgs-unstable.tailscale;
    };
    networking.nameservers = [ "100.100.100.100" "9.9.9.9" "8.8.8.8" "1.1.1.1" ];
    networking.search = [ "tail546fb.ts.net" ];
    networking.firewall.checkReversePath = "loose";
  };
}
