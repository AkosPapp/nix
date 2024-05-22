{ config, lib, modulesPath, nixos-hardware, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    nixos-hardware.nixosModules.lenovo-legion-16ach6h-nvidia
  ];

  config = {

    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;

      initrd = {
        availableKernelModules =
          [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
      };
      kernelModules = [ "kvm-amd" ];
      #kernelPackages = pkgs.linuxPackages_latest;
      extraModulePackages = [
        config.boot.kernelPackages.nvidia_x11
        config.boot.kernelPackages.lenovo-legion-module
      ];
      supportedFilesystems = [ "zfs" ];
      zfs = {
        extraPools = [ "zroot" ];
        forceImportRoot = false;
        allowHibernation = true;
      };
      resumeDevice = "/dev/disk/by-partlabel/disk-samsung980-swap";
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

    hardware.nvidia = {

      # Modesetting is required.
      modesetting.enable = true;

      # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
      # Enable this if you have graphical corruption issues or application crashes after waking
      # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead 
      # of just the bare essentials.
      powerManagement.enable = false;

      # Fine-grained power management. Turns off GPU when not in use.
      # Experimental and only works on modern Nvidia GPUs (Turing or newer).
      powerManagement.finegrained = false;

      # Use the NVidia open source kernel module (not to be confused with the
      # independent third-party "nouveau" open source driver).
      # Support is limited to the Turing and later architectures. Full list of 
      # supported GPUs is at: 
      # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus 
      # Only available from driver 515.43.04+
      # Currently alpha-quality/buggy, so false is currently the recommended setting.
      open = false;

      # Enable the Nvidia settings menu,
      # accessible via `nvidia-settings`.
      nvidiaSettings = true;

      # Optionally, you may need to select the appropriate driver version for your specific GPU.
      package = config.boot.kernelPackages.nvidiaPackages.stable;
      prime = {
        sync.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        amdgpuBusId = "PCI:6:0:0";
      };
    };
  };
}
