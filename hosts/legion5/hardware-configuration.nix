{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disko.nix
  ];

  config = {
    boot = {
      loader = {
        grub = {
          enable = true;
          efiSupport = true;
          device = "nodev";
          useOSProber = true;
        };
        efi. canTouchEfiVariables = true;
      };
      kernelParams = [
        "module_blacklist=amdgpu"
        "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
        "nvidia.NVreg_TemporaryFilePath=/var/tmp"
      ];
      extraModulePackages = [
        config.boot.kernelPackages.nvidia_x11
      ];
    };

    PROFILES.zroot.enable = true;

    fileSystems = {
      "/etc/NetworkManager/system-connections" = {
        device = "zroot/persist/system-connections";
        fsType = "zfs";
      };

      "/home" = {
        device = "zroot/persist/home";
        fsType = "zfs";
      };

      "/home/akos" = {
        device = "zroot/persist/home/akos";
        fsType = "zfs";
      };

      "/boot" = {
        fsType = "vfat";
        options = ["fmask=0022" "dmask=0022"];
      };
    };

    swapDevices = [
      {device = "/dev/disk/by-label/NIXOS_SWAP";}
    ];

    networking = {
      networkmanager.enable = true;
      hostId = "68bf4e0e";
      hostName = "legion5";
    };
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode =
      lib.mkDefault config.hardware.enableRedistributableFirmware;

    powerManagement.cpuFreqGovernor = "performance";
    services.xserver.videoDrivers = ["nvidia"];
    hardware.cpu.x86.msr.enable = true;
    hardware.cpu.x86.msr.settings.allow-writes = "on";
    hardware.nvidia = {
      # Modesetting is required.
      modesetting.enable = true;

      # Nvidia power management. Experizenpowermental, and can cause sleep/suspend to fail.
      # Enable this if you have graphical corruption issues or application crashes after waking
      # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead
      # of just the bare essentials.
      powerManagement.enable = true;

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

      #nvidiaPersistenced = true;

      # Enable the Nvidia settings menu,
      # accessible via `nvidia-settings`.
      nvidiaSettings = true;

      # Optionally, you may need to select the appropriate driver version for your specific GPU.
      package = config.boot.kernelPackages.nvidiaPackages.latest;
      prime = {
        sync.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        amdgpuBusId = "PCI:6:0:0";
      };
    };
    users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
  };
}
