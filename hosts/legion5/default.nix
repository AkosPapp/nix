{
  config,
  pkgs,
  lib,
  nixos-version,
  ...
}: {
  imports = [./hardware-configuration.nix ./disko.nix ./sops.nix];

  networking = {
    networkmanager.enable = true;
    hostId = "68bf4e0e";
    hostName = "legion5";
    extraHosts = ''
      127.0.0.1 localhost
    '';
  };

  MODULES.system.printing.enable = true;

  USERS.akos.enable = true;

  users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

  services.xserver.displayManager.gdm.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    nvidia-container-toolkit
    cudatoolkit
  ];

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      libvdpau-va-gl
    ];
  };

  services.logind = {
    powerKey = "suspend";
    lidSwitch = "suspend";
  };

  services.znapzend = {
    enable = true;
    pure = true;
    autoCreation = true;
    logLevel = "debug";
    logTo = "/var/log/znapzend.log";
    # features = {
    #   compressed = true;
    #   lowmemRecurse = true;
    #   skipIntermediates = true;
    # };
    zetup."zroot/persist" = {
      recursive = true;
      plan = "1h=>1min,1d=>1h,1w=>1d";
      enable = true;
      destinations = {
        hp = {
          host = "root@hp";
          dataset = "zroot/persist";
          plan = "1h=>1min,1d=>1h,1w=>1d";
        };
      };
    };
  };
  systemd.services.znapzend.serviceConfig.ExecStart = let
    args = lib.concatStringsSep " " [
      "--logto=${config.services.znapzend.logTo}"
      "--loglevel=${config.services.znapzend.logLevel}"
      "--autoCreation"
      "--debug"
    ];
  in
    lib.mkForce "${pkgs.znapzend}/bin/znapzend ${args}";

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "weekly";
    };
    trim = {
      enable = true;
      interval = "daily";
    };
  };

  services.power-profiles-daemon.enable = true;
}
