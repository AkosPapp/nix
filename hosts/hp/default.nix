{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  services.tailscale = {
    extraSetFlags = ["--advertise-exit-node=true"];
    useRoutingFeatures = "both";
  };

  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;
  MODULES.security.sops.enable = true;

  MODULES.networking.traefik.enable = true;
  MODULES.services.homepage.enable = true;
  MODULES.services.grafana.enable = true;
  MODULES.services.prometheus.enable = true;
  MODULES.services.sftpgo.enable = true;
  MODULES.services.i2pd.enable = true;
  MODULES.services.ipfs.enable = true;
  MODULES.services.transmission.enable = true;
  MODULES.services.searx.enable = true;
  MODULES.services.roundcube.enable = true;
  MODULES.services.nextcloud.enable = true;
  MODULES.services.nextcloud.hostName = config.networking.fqdn;

  MODULES.nix.substituters.akos01.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandlePowerKey = "ignore";
  };

  services.cron = {
    enable = true;
    systemCronJobs = [
      "0 5 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g performance"
      "0 5 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=20000 --fast-limit=30000 --slow-limit=15000 --tctl-temp=90"

      "30 20 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g powersave -d 100 -u 100"
      "30 20 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=500 --fast-limit=1000 --slow-limit=100 --tctl-temp=30"
    ];
  };
}
