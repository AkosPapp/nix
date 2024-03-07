{ config, lib, pkgs, modulesPath, ... }:

{
    imports = [ 
        (modulesPath + "/installer/scan/not-detected.nix")
    ];

    config = {

        boot = {
            loader.systemd-boot.enable = true;
            loader.efi.canTouchEfiVariables = true;

            initrd = {
                availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
                kernelModules = [ ];
            };
            kernelModules = [ "kvm-amd" ];
#extraModulePackages = [ ];
            supportedFilesystems = [ "zfs" ];
            zfs.extraPools = [ "home" ];
            zfs.forceImportRoot = false;
        };
#boot.zfs.allowHibernation = true;

        fileSystems."/" =
        { device = "/dev/disk/by-uuid/b8b720e7-e6cd-4413-b11e-fc632f5ee6a0";
            fsType = "ext4";
        };

        fileSystems."/boot" =
        { device = "/dev/disk/by-uuid/B04A-ACB1";
            fsType = "vfat";
        };


        swapDevices = [
        { device = "/dev/disk/by-uuid/82d5dd31-7de1-4c3c-96fe-994453eff873"; }
        ];

        networking.useDHCP = lib.mkDefault true;
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    };
}
