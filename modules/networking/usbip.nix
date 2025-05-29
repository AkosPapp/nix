{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.usbip.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable USB/IP support";
    };
  };

  config = lib.mkIf config.MODULES.networking.usbip.enable {
    boot.extraModulePackages = with pkgs; [
      linuxPackages_latest.usbip
    ];
    environment.systemPackages = with pkgs; [
      linuxPackages_latest.usbip
    ];
    boot.initrd.kernelModules = ["vhci_hcd"];
  };
}
