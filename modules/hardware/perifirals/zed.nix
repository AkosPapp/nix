{
  config,
  lib,
  ...
}: let
  cfg = config.MODULES.hardware.perifirals.zed;
in {
  options.MODULES.hardware.perifirals.zed.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Keep the Stereolabs ZED 2i capture camera (USB vendor 2b03) out of USB runtime suspend.";
  };

  config = lib.mkIf cfg.enable {
    # The kernel's default USB power policy (power/control=auto, ~2 s idle delay) runtime-suspends
    # the ZED whenever the UVC pipe is not actively streaming. sl::Camera::open() has exactly such
    # idle windows while it probes and starts the streams, so the suspend lands mid-startup: the
    # camera power-cycles, the SDK logs a CAMERA REBOOTING storm and dies with "CAMERA STREAM
    # FAILED TO START", and sysfs shows the device re-enumerating (the PLUG OUT/IN events in
    # tools/nurec/capture/zed/usb_check.py link --watch). Pinning control=on at add time keeps the
    # link powered; the rule re-applies on every enumeration, which is what a cable replug is.
    # Caveat: power-profiles-daemon (enabled on legion5) rewrites power/control on profile
    # switches and can re-arm suspend - capture/zed/run.sh checks and repairs this before every
    # docker run, and usb_check.py link fails loudly while autosuspend is armed.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="2b03", ATTR{power/control}="on"
    '';
  };
}
