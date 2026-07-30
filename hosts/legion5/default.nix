{
  pkgs,
  config,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  #MODULES.nix.substituters.proxy.enable = true;
  MODULES.system.printing.enable = true;
  MODULES.hardware.nvidia.enable = true;
  USERS.akos.enable = true;
  MODULES.networking.tailscale.hostIP = "100.126.232.60";
  MODULES.services.syncthing.deviceID = "U6G2UZ4-RX5WVKR-5MAIXOA-4GX6ZL6-PGTAPWD-KXLK3V4-N4EPLT3-GWR7MQ7";
  # Shares live under akos's home directory, which the default "syncthing" system user can't
  # read; run as akos instead (see MODULES.services.syncthing.user's description for why
  # running as root doesn't work for this).
  MODULES.services.syncthing.user = "akos";
  MODULES.services.syncthing.group = "users";
  MODULES.services.syncthing.shares = [
    {
      path = "/home/akos/Pictures/dcim";
      copyOwnershipFromParent = true;
      extra_devices = ["phone"];
    }
    {
      # Everything under ~/Pictures (including dcim, see above) mirrored to hp - moving a phone
      # photo out of dcim into any other spot under here is how it stops being tied to the phone's
      # camera roll: from then on it's just a plain legion5<->hp synced file, immune to whatever
      # happens on the phone. dcim itself is excluded here since it's already its own folder above
      # (synced with the phone too) - without excluding it, this folder and the dcim one above
      # would both try to manage the same files, which Syncthing does not handle well.
      path = "/home/akos/Pictures";
      copyOwnershipFromParent = true;
      ignorePatterns = ["/dcim"];
    }
    {
      path = "/home/akos/notes";
      copyOwnershipFromParent = true;
      extra_devices = ["phone"];
    }
  ];
  PROFILES.zroot.enable = true;
  services.displayManager.ly.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    lm_sensors
    psutils
    runc
    cudatoolkit
  ];

  boot.extraModulePackages = with config.boot.kernelPackages; [
    lenovo-legion-module
  ];

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "sleep";
    HandlePowerKey = "sleep";
  };

  services.znapzend = {
    enable = true;
    pure = true;
    autoCreation = true;
    logLevel = "debug";
    logTo = "/var/log/znapzend.log";
    features = {
      # compressed = true;
      lowmemRecurse = true;
      # skipIntermediates = true;
    };
    zetup."zroot/persist/legion5" = {
      recursive = true;
      plan = "1h=>1min,1d=>1h,1w=>1d,5m=>1w";
      #plan = "1h=>1min,1d=>1h,1w=>1d";
      enable = true;
      destinations = {
        # hp = {
        # host = "root@hp";
        # dataset = "zroot/persist/legion5";
        # plan = "1h=>1min,1d=>1h,1w=>1d";
        # };
      };
    };
  };
  # systemd.services.znapzend.serviceConfig.ExecStart = let
  #   args = lib.concatStringsSep " " [
  #     "--logto=${config.services.znapzend.logTo}"
  #     "--loglevel=${config.services.znapzend.logLevel}"
  #     "--autoCreation"
  #     "--debug"
  #   ];
  # in
  #   lib.mkForce "${pkgs.znapzend}/bin/znapzend ${args}";

  services.power-profiles-daemon.enable = true;

  # Set rtprio limits for real-time priority
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "-";
      item = "rtprio";
      value = "98";
    }
  ];

  # Increase network buffer sizes
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 20971520;
    "net.core.rmem_default" = 20971520;
    "net.core.wmem_max" = 20971520;
    "net.core.wmem_default" = 20971520;
  };
}
