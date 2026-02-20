{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.system.printing.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable printing support";
    };
  };

  config = lib.mkIf config.MODULES.system.printing.enable {
    services.printing = {
      enable = true;
      drivers = with pkgs; [
        gutenprint
        canon-cups-ufr2
        cups-filters
        samsung-unified-linux-driver
        pkgs.samsung-unified-linux-driver_1_00_37
        ptouch-driver
      ];
    };

    hardware.sane.enable = true;
    hardware.sane.extraBackends = with pkgs; [
      samsung-unified-linux-driver_1_00_37
      samsung-unified-linux-driver
    ];

    environment.systemPackages = with pkgs; [
      hplipWithPlugin
      xsane
      simple-scan
      dbus
      cups-pk-helper
      avahi
      libjpeg
      libthreadar
      libusb1
      sane-airscan
      libtool
      python313Packages.notify2
      sane-backends
    ];

    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
  };
}
