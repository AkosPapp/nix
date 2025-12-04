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

  networking = {
    useDHCP = lib.mkForce true;
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandlePowerKey = "ignore";
  };
  MODULES.nix.substituters.akos01.enable = true;
}
