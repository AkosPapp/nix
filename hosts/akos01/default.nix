{
  config,
  pkgs,
  lib,
  nixos-version,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.searx.enable = true;
  MODULES.networking.tailscale.hostIP = "100.71.138.61";
  MODULES.nix.builders.airlab = true;
  MODULES.security.vaultwarden.enable = true;
  PROFILES.qemu-vm.enable = true;
  PROFILES.server.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    git
    htop
    tmux
    dnsutils
  ];

  # extra tailscale config
  services.tailscale = {
    extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24"];
    useRoutingFeatures = "both";
  };

  # nix-serve
  MODULES.security.sops.enable = true;
  sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key" = {
    mode = "0400";
    #owner = "nix-serve";
    #group = "nix-serve";
  };
  services.nix-serve = {
    enable = true;
    secretKeyFile = config.sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key".path;
  };

  users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

  services.logind = {
    powerKey = "ignore";
    lidSwitch = "ignore";
  };

  nix = {
    settings = {
      download-buffer-size = 524288000; # 500 MiB
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
