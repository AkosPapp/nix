{
  config,
  pkgs,
  lib,
  nixos-version,
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
  MODULES.networking.traefik.enable = true;
  MODULES.security.sops.enable = true;
  MODULES.services.homepage.enable = true;
  MODULES.services.grafana.enable = true;
  MODULES.services.prometheus.enable = true;
  MODULES.services.sftpgo.enable = true;
  MODULES.services.i2pd.enable = true;
  MODULES.services.ipfs.enable = true;
  MODULES.services.transmission.enable = true;
  MODULES.services.searx.enable = true;
  MODULES.nix.substituters.akos01.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandlePowerKey = "ignore";
  };
}
