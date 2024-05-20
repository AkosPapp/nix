{ config, pkgs, lib, nixos-hardware, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  #  # Bootloader.
  #  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking = {
    networkmanager.enable = true;
    hostId = "68bf4e0e";
    hostName = "legion5";
    extraHosts = ''
      127.0.0.1 localhost 
    '';
  };

  MODULES.system.printing.enable = true;

  users.users.root.hashedPassword =
    "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "23.11";

  USERS.akos.enable = true;

  services.xserver.displayManager.sddm = { enable = true; };

  environment.systemPackages = with pkgs; [ lenovo-legion ];

  # Enable OpenGL
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  hardware.nvidia.prime.amdgpuBusId = "PCI:6:0:0";

  services.logind = {
    powerKey = "hibernate";
    lidSwitch = "hibernate";
  };

  services.znapzend = {
    enable = true;
    pure = true;
    features.compressed = true;
    zetup."zroot/persist" = {
      recursive = true;
      plan = "1h=>1min,1d=>1h,1m=>1d";
      enable = true;
    };
  };

  #services.zfs = {
  #  autoScrub = {
  #    enable = true;
  #    interval = "weekly";
  #  };
  #  trim = {
  #    enable = true;
  #    interval = "daily";
  #  };
  #};

  virtualisation.docker.enableNvidia = true;

  services.power-profiles-daemon.enable = true;
}

