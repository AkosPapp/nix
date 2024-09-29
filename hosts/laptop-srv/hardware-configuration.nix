{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  config = {
    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;

      initrd = {
        availableKernelModules = ["nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod"];
        kernelModules = [];
      };
      kernelModules = ["kvm-amd"];
      #extraModulePackages = [ ];
      supportedFilesystems = ["zfs"];
      zfs = {
        extraPools = ["zroot"];
        forceImportRoot = true;
        allowHibernation = false;
      };
    };

    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
    };

    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
    };

    fileSystems."/home/akos" = {
      device = "zroot/persist/home/akos";
      fsType = "zfs";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-partlabel/disk-samsung980-ESP";
      fsType = "vfat";
      options = ["fmask=0022" "dmask=0022"];
    };

    swapDevices = [
      {device = "/dev/disk/by-partlabel/disk-samsung980-swap";}
    ];

    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
