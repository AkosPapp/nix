{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  config = {

    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;

      initrd = {
        availableKernelModules =
          [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
        kernelModules = [ "nvidia" ];
      };
      kernelModules = [ "kvm-amd" ];
      #kernelPackages = pkgs.linuxPackages_latest;
      kernelParams = [ "amdgpu.sg_display=0" ];
      extraModulePackages = [
        config.boot.kernelPackages.nvidia_x11
        config.boot.kernelPackages.lenovo-legion-module
      ];
      supportedFilesystems = [ "zfs" ];
      zfs.extraPools = [ "zroot" ];
      zfs.forceImportRoot = true;
    };

    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
    };

    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
    };

    fileSystems."/etc/NetworkManager/system-connections" = {
      device = "zroot/persist/system-connections";
      fsType = "zfs";
    };

    fileSystems."/home" = {
      device = "zroot/persist/home";
      fsType = "zfs";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-partlabel/disk-samsung980-ESP";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

    swapDevices = [
      { device = "/dev/disk/by-partlabel/disk-samsung980-swap"; }
      { device = "/dev/disk/by-partlabel/disk-samsung-pm9a1-swap"; }
    ];

    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
