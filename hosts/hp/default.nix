{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  services.tailscale = {
    # extraSetFlags = ["--advertise-exit-node=true"];
    # extraSetFlags = ["--accept-dns=true" "--accept-routes=true"];
    useRoutingFeatures = "both";
  };

  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;
  MODULES.security.sops.enable = true;
  # MODULES.system.printing.enable = true;
  # services.printing.openFirewall = true;
  # services.printing.listenAddresses = [
  #   "127.0.0.1:${toString config.PORTS.cups}"
  #   "${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.cups}"
  # ];
  # services.printing.allowFrom = ["all"];
  # MODULES.networking.traefik.path_routes = {
  #   "/cups" = "http://127.0.0.1:${toString config.PORTS.cups}";
  # };

  # MODULES.networking.traefik.enable = true;
  # MODULES.services.homepage.enable = true;
  # MODULES.services.grafana.enable = true;
  # MODULES.services.prometheus.enable = true;
  # MODULES.services.sftpgo.enable = true;
  # MODULES.services.i2pd.enable = true;
  # MODULES.services.ipfs.enable = true;
  # MODULES.services.transmission.enable = true;
  # MODULES.services.searx.enable = true;
  # MODULES.services.roundcube.enable = true;
  # MODULES.services.nextcloud.enable = true;
  # MODULES.services.nextcloud.hostName = config.networking.fqdn;

  MODULES.nix.substituters.akos01.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  # services.logind.settings.Login = {
  #   HandleLidSwitch = "ignore";
  #   HandlePowerKey = "ignore";
  # };

  # services.cron = {
  #   enable = true;
  #   systemCronJobs = [
  #     "0 5 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g performance"
  #     "0 5 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=20000 --fast-limit=30000 --slow-limit=15000 --tctl-temp=90"

  #     "30 20 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g powersave -d 100 -u 100"
  #     "30 20 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=500 --fast-limit=1000 --slow-limit=100 --tctl-temp=30"
  #   ];
  # };

  ## temporary, to be removed when the new hardware is set up

  MODULES.system.printing.enable = true;
  USERS.akos.enable = true;
  services.displayManager.gdm.enable = true;

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
    zetup."zroot/persist/legion5" = {
      recursive = true;
      plan = "1h=>1min,1d=>1h,1w=>1d";
      enable = true;
      destinations = {
        # hp = {
        #   host = "root@hp";
        #   dataset = "zroot/persist/legion5";
        #   plan = "1h=>1min,1d=>1h,1w=>1d";
        # };
      };
    };
  };

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

  # fileSystems = {
  #   "/etc/NetworkManager/system-connections" = {
  #     device = "zroot/persist/legion5/system-connections";
  #     fsType = "zfs";
  #   };

  #   "/home" = {
  #     device = "zroot/persist/legion5/home";
  #     fsType = "zfs";
  #   };

  #   "/home/akos" = {
  #     device = "zroot/persist/home/akos";
  #     fsType = "zfs";
  #   };
  # };

  networking = {
    networkmanager.enable = lib.mkForce true;
  };
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
