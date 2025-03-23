{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.airlab-vpn.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable AIRlab VPN";
    };
  };

  config = lib.mkIf config.MODULES.networking.airlab-vpn.enable {
    MODULES.security.sops.enable = true;
    sops.secrets."wireguard/airlab" = {};
    networking.wg-quick.interfaces.airlab.configFile = config.sops.secrets."wireguard/airlab".path;
  };
}
