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
      extraModulePackages = [ config.boot.kernelPackages.nvidia_x11 ];
      supportedFilesystems = [ "zfs" ];
      zfs.extraPools = [ "zroot" ];
      zfs.forceImportRoot = true;
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-partlabel/disk-samsung980-ESP";
      fsType = "vfat";
    };

    swapDevices = [
      { device = "/dev/disk/by-partlabel/disk-samsung980-swap"; }
      { device = "/dev/disk/by-partlabel/disk-samsung980-swap"; } # FIXTHIS
    ];

    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
