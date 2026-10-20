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
    # the ZED whenever the UVC pipe is not actively streaming, which adds suspend/resume churn and
    # a wake delay inside the SDK's idle windows (long neural-depth optimization on first open,
    # retry gaps). Belt and braces: control=on pins the device awake, autosuspend=-1 kills the idle
    # timer even if something (or the PM init race after add) puts control back to auto — on the
    # 2026-10-20 replug test the bare control=on write had not survived re-enumeration. Both
    # re-apply on every enumeration, which is what a cable replug is. Kernel -71/-110 EPROTO
    # errors around stream start remain the cable/port, not PM. Caveat: power-profiles-daemon
    # rewrites power/control on profile switches; the autosuspend=-1 fallback covers that too.
    # capture/zed/run.sh checks before every docker run, and usb_check.py link fails while a
    # positive autosuspend delay is armed.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="2b03", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
    '';
  };
}
