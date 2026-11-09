{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.MODULES.virtualisation.windowsUsbHotplug;

  # Talks to the dockur/windows VM's QEMU human monitor over the unix socket exposed by
  # the MONITOR env var in ~/Projects/windows-docker/docker-compose.yml, and re-attaches
  # (or detaches) a passed-through USB device. A static `-device usb-host,vendorid=...`
  # only binds at QEMU startup: after a Windows-side eject + physical replug the guest
  # never sees the device again (dockur/windows#1675, still open). QEMU's supported path
  # is device_add on the monitor, which is what the udev rules below trigger on every
  # enumeration. `add` runs device_del first so it is idempotent and clears the stale
  # attach QEMU leaves behind when the device is yanked while assigned
  # (libusb_release_interface -4 [NO_DEVICE]). A 1 s grace keeps the host's driver
  # (e.g. r8152 auto-binding on enumeration) from racing the claim; libusb would detach
  # it anyway. python3 instead of socat: it needs the greeting-drain + per-command pacing.
  hotplug = pkgs.writeShellApplication {
    name = "windows-usb-hotplug";
    runtimeInputs = [pkgs.python3];
    text = ''
      usage() {
        echo "usage: $0 SOCKET {add|remove} QOM_ID [VID PID]" >&2
        exit 1
      }
      [ "$#" -ge 3 ] || usage
      sock="$1" action="$2" id="$3"

      case "$action" in
        add)
          [ "$#" -eq 5 ] || usage
          sleep 1
          # Stale attach (if any) under this id, then a fresh claim. If the device is
          # already attached under a different id, device_add just fails harmlessly.
          MON_CMD="device_del $id
      device_add usb-host,id=$id,vendorid=0x$4,productid=0x$5"
          ;;
        remove)
          MON_CMD="device_del $id"
          ;;
        *) usage ;;
      esac

      [ -S "$sock" ] || { echo "$sock not found - windows container up with MONITOR set?" >&2; exit 1; }

      MON_SOCK="$sock" MON_CMD="$MON_CMD" python3 - <<'PY'
      import os, socket, time
      s = socket.socket(socket.AF_UNIX)
      s.settimeout(5)
      s.connect(os.environ["MON_SOCK"])
      try:
          s.recv(4096)  # monitor greeting
      except Exception:
          pass
      for line in os.environ["MON_CMD"].splitlines():
          s.sendall((line + "\n").encode())
          time.sleep(0.3)
          try:
              print(s.recv(4096).decode(errors="replace"), end="")
          except Exception:
              pass
      s.close()
      PY
    '';
  };

  ruleFor = d: ''
    # ${d.name} (USB ${d.vid}:${d.pid}) pass-through to the windows VM
    ACTION=="add",    SUBSYSTEM=="usb", ATTR{idVendor}=="${d.vid}", ATTR{idProduct}=="${d.pid}", RUN+="${hotplug}/bin/windows-usb-hotplug ${cfg.monitorSocket} add ${d.name} ${d.vid} ${d.pid}"
    ACTION=="remove", SUBSYSTEM=="usb", ATTR{idVendor}=="${d.vid}", ATTR{idProduct}=="${d.pid}", RUN+="${hotplug}/bin/windows-usb-hotplug ${cfg.monitorSocket} remove ${d.name}"
  '';
in {
  options.MODULES.virtualisation.windowsUsbHotplug = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "udev rules re-attaching USB devices to the dockur/windows QEMU VM on replug, via its monitor socket.";
    };

    monitorSocket = lib.mkOption {
      type = lib.types.str;
      default = "/home/akos/Projects/windows-docker/windows/monitor.sock";
      description = "QEMU monitor unix socket of the windows container (the MONITOR env var target, inside the bind-mounted storage dir).";
    };

    devices = lib.mkOption {
      type = with lib.types; listOf (attrsOf str);
      default = [
        {
          name = "rtl8153";
          vid = "0bda";
          pid = "8153";
        }
      ];
      example = [
        {
          name = "rtl8153";
          vid = "0bda";
          pid = "8153";
        }
      ];
      description = "Devices to keep hot-pluggable: QOM id (must match the id= in the compose ARGUMENTS) plus vid/pid hex without 0x.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.udev.extraRules = lib.concatMapStringsSep "\n" ruleFor cfg.devices;
    environment.systemPackages = [hotplug];
  };
}
