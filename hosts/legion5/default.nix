{pkgs, ...}: {
  imports = [./hardware-configuration.nix];

  MODULES.nix.substituters.akos01.enable = true;
  MODULES.system.printing.enable = true;
  MODULES.hardware.nvidia.enable = false;
  USERS.akos.enable = true;
  MODULES.networking.tailscale.hostIP = "100.125.194.29";
  PROFILES.zroot.enable = true;
  services.displayManager.gdm.enable = true;
  # MODULES.services.openclaw.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    lm_sensors
    psutils
    runc
    cudatoolkit
  ];

  boot.extraModulePackages = with pkgs; [
    linuxPackages_6_12.lenovo-legion-module
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
          dataset = "zroot/persist/legion5";
          plan = "1h=>1min,1d=>1h,1w=>1d";
        };
      };
    };
  };
  #  systemd.services.znapzend.serviceConfig.ExecStart = let
  #    args = lib.concatStringsSep " " [
  #      "--logto=${config.services.znapzend.logTo}"
  #      "--loglevel=${config.services.znapzend.logLevel}"
  #      "--autoCreation"
  #      "--debug"
  #    ];
  #  in
  #    lib.mkForce "${pkgs.znapzend}/bin/znapzend ${args}";

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
