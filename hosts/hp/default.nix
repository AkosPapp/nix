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

  services.logind = {
    powerKey = "ignore";
    lidSwitch = "ignore";
  };

  nix = {
    settings = {
      substituters = [
        "https://akos01.tail546fb.ts.net:8443"
        "https://nix-community.cachix.org"
        "https://cache.nixos.org/"
      ];
      trusted-substituters = [
        "https://akos01.tail546fb.ts.net:8443"
        "https://nix-community.cachix.org"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [
        "akos01.tail546fb.ts.net:sLx+ag0KitVYyMj8GVwO99o58QXWZRRXbDp6YSecrmc="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };
}
