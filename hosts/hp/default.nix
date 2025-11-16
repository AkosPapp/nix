{
  config,
  pkgs,
  lib,
  nixos-version,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;

  networking = {
    hostId = "68bf4e0e";
    hostName = "hp";
    useDHCP = lib.mkForce true;
  };

  services.logind = {
    powerKey = "ignore";
    lidSwitch = "ignore";
  };

  nix = {
    settings = {
      substituters = [
        "http://akos01.tail546fb.ts.net:5000"
        "https://nix-community.cachix.org"
        "https://cache.nixos.org/"
      ];
      trusted-substituters = [
        "http://akos01.tail546fb.ts.net:5000"
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
