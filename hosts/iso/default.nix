{ pkgs, modulesPath, my-nixvim, system, ... }: {
  imports = [
  "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
  services.openssh.settings.PermitRootLogin = pkgs.lib.mkForce "yes";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCYoxGrmlgUcVfncMnlDONPk5RwSEqbiBpvT3c2m9MIDsYdYlLfnRN5YJPZgp8CHcPnPK2rboRiHAO00j545ci2CDeAp6zGKoOhX0q/3fES3ySqMG7lJ+cplxoXekSL9GNOQqSREDymqrMfqGy9OnupqcAZForX/k1aegi99TgZwbGMAK/UIzfdkQr49VVzYbaNR14rikIfjvi23s4bdP/KgeAs0T9KEKKSAd9WJQxUr/dmTjNBODzW10llgmCCVRNk3Pj4A1qiGiz0wkjG7XmZT0QjHyrX2GzSYuhW1l8s6mY3tTBBKVoj+peBphgxGBbEwUCQh0yPVBGstM5fHqN1bvOjRfYNQboVSmLhicX7Bk0WNLPS6DtqHZTXGNuYM8NcHn4xUIX5GwlsS6Mfo2tDMcX83w1Jv0BuImfcUMl6jvYCzcpEdGENYHWisIvQLSlAK6UEIYGeG8CH/iRqRPQIrOW49EQJYlW2VSLuTf8SA6c9Z2xdSIsli9JOfr79VUdYpgrdiv7vFjiX5d+hcJVC0rjQkF6XlAWVH5yMfpr1OXFbpKqILygx9Zcj7IhMHodQsjtr6+FjIs5Xm5Nt1nY9Cpke/q3lHcgq0PVgwvMPMhTOxfv6XoKQGmDTJWsmAP8n4BotZm7H2OlO29/zJnrgJ8+ZienkAX5s2cAaT16Kvw== akos@laptop"
  ];

  MODULES = {
    fonts.nerdfonts.enable = true;
    system.binbash.enable = true;
    system.gpg.enable = true;
    system.sound.enable = true;
    wm.dwm.enable = true;
  };

  environment.systemPackages = with pkgs; [
    firefox
    my-nixvim.packages.${system}.default
    keepassxc
    rsync
    sanoid
    lz4

  ];

  home-manager = {
    useGlobalPkgs = true;
    users.nixos.home = {
      username = "nixos";
      homeDirectory = "/home/nixos";
      packages = [ my-nixvim.packages.${system}.default ];
      stateVersion = "23.11";
    };
    users.root.home = {
      username = "root";
      homeDirectory = "/root";
      packages = [ my-nixvim.packages.${system}.default ];
      stateVersion = "23.11";
    };
  };

  sops.defaultSopsFile = ../../secrets/example.yaml;
  #sops.secrets."repos.PPAPSONKA.nix.deploy-key.iso.private" = {};
}
