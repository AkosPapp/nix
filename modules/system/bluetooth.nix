{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.system.bluetooth.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable bluetooth support";
    };
  };

  config = lib.mkIf config.MODULES.system.bluetooth.enable {
    services.blueman.enable = true;
    hardware.bluetooth.enable = true;
    environment.systemPackages = with pkgs; [bluez bluez-tools];
  };
}
