{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.netbird.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Netbird VPN";
    };
  };

  config = lib.mkIf config.MODULES.networking.netbird.enable {
    environment.systemPackages = with pkgs; [
      netbird
      netbird-ui
    ];
    services.netbird = {
      enable = true;
    };
  };
}
