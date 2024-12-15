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
    networking.search = ["tail546fb.ts.net"];
    networking.firewall.checkReversePath = "loose";
    networking.nameservers = [
      #"172.16.0.1"
      #"100.100.100.100"
      #"9.9.9.9"
      #"8.8.8.8"
      #"1.1.1.1"
      "127.0.0.1"
    ];
    services.dnsmasq = {
      enable = true;
    };
    environment.etc = {
      "dnsmasq-conf.conf" = {
        source = ./dnsmasq.conf;
        mode = "0644";
      };
    };
  };
}
