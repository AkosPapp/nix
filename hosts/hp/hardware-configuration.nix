{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disko.nix
  ];

  PROFILES.zroot.enable = true;

  fileSystems = {
    "/boot" = {
      fsType = "vfat";
      options = ["fmask=0022" "dmask=0022"];
    };

    # dedicated ZFS dataset for sftpgo data
    "/var/lib/sftpgo" = {
      device = "zroot/persist/hp/sftpgo";
      fsType = "zfs";
    };
  };

  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Ryzen SMU driver for fan control and temperature monitoring
  boot.extraModulePackages = with config.boot.kernelPackages; [ryzen-smu];
  boot.kernelModules = ["ryzen_smu"];

  environment.systemPackages = with pkgs; [
    ryzenadj
    lm_sensors
    config.boot.kernelPackages.turbostat
  ];

  powerManagement.cpuFreqGovernor = "performance";

  # The console-root password (2026-10-24 audit #1: the old hash was committed and identical
  # to legion5's root AND the akos account). sops-held, rotated, neededForUsers so it exists
  # when users-activation reads it. Rotate with:
  #   sops set sops/secrets.yaml '["passwords","root"]' '"$(mkpasswd -m yescrypt)"'
  # then re-deploy. SSH stays key-only; this guards the physical console only.
  sops.secrets."passwords/root" = {
    neededForUsers = true;
    mode = "0400";
  };
  users.users.root.hashedPasswordFile = config.sops.secrets."passwords/root".path;
}
