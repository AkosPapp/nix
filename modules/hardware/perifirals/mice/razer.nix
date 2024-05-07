{ config, pkgs, lib, ... }: {
  options = {
    MODULES.hardware.perifirals.mice.razer.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the OpenSSH daemon.";
    };
  };

  config = lib.mkIf config.MODULES.hardware.perifirals.mice.razer.enable {
    hardware.openrazer = {
      verboseLogging = false;
      syncEffectsEnabled = true;
      mouseBatteryNotifier = true;
      keyStatistics = false;
      enable = true;
      devicesOffOnScreensaver = true;
    };
  };

}
