{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.dnsmasq.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable dnsmasq";
    };
  };

  config = lib.mkIf config.MODULES.networking.dnsmasq.enable {
    services.resolved.enable = false;
    networking.resolvconf.enable = false;
    networking.networkmanager.dns = "dnsmasq";
    networking.nameservers = ["127.0.0.1"];
    services.dnsmasq = {
      enable = true;
    };
    environment.etc = {
      "dnsmasq-conf.conf" = {
        source = ./dnsmasq-conf.conf;
        mode = "0644";
      };
    };
  };
}
