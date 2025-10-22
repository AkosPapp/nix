{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  ...
}: {
  config = {
    MODULES.nix.builders.airlab = true;
    MODULES.security.vaultwarden.enable = true;
    MODULES.networking.tailscale.hostIP = "100.71.138.61";
    MODULES.networking.traefik.enable = true;
    PROFILES.qemu-vm.enable = true;

    networking = {
      hostName = "akos01";
      useDHCP = true;
    };

    services.tailscale = {
      extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24"];
      useRoutingFeatures = "both";
    };
  };
}
