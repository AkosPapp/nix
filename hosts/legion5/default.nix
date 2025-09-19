{
  config,
  pkgs,
  lib,
  nixos-version,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.system.printing.enable = true;
  MODULES.nix.builders.build-host = false;
  MODULES.nix.builders.airlab = false;
  USERS.akos.enable = true;
  services.xserver.displayManager.gdm.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    nvidia-container-toolkit
    runc
    cudatoolkit
  ];

  boot.extraModulePackages = with pkgs; [
    #linuxPackages_latest.liquidtux
    linuxPackages_latest.lenovo-legion-module
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

  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.docker.daemon.settings.features.cdi = true;

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
        #hp = {
        #  host = "root@hp";
        #  dataset = "zroot/persist";
        #  plan = "1h=>1min,1d=>1h,1w=>1d";
        #};
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
}
