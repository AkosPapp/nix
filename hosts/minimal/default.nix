{
  config,
  pkgs,
  lib,
  nixos-hardware,
  sops-nix,
  ...
}: {
  imports = [./hardware-configuration.nix];

  networking = {
    hostId = "68bf4e0e";
    hostName = "minimal";
    extraHosts = ''
      127.0.0.1 localhost
    '';
  };

  users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

  system.stateVersion = "24.05";

  MODULES.networking.sshd.enable = true;

  services.openssh.settings.PermitRootLogin = pkgs.lib.mkForce "yes";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCYoxGrmlgUcVfncMnlDONPk5RwSEqbiBpvT3c2m9MIDsYdYlLfnRN5YJPZgp8CHcPnPK2rboRiHAO00j545ci2CDeAp6zGKoOhX0q/3fES3ySqMG7lJ+cplxoXekSL9GNOQqSREDymqrMfqGy9OnupqcAZForX/k1aegi99TgZwbGMAK/UIzfdkQr49VVzYbaNR14rikIfjvi23s4bdP/KgeAs0T9KEKKSAd9WJQxUr/dmTjNBODzW10llgmCCVRNk3Pj4A1qiGiz0wkjG7XmZT0QjHyrX2GzSYuhW1l8s6mY3tTBBKVoj+peBphgxGBbEwUCQh0yPVBGstM5fHqN1bvOjRfYNQboVSmLhicX7Bk0WNLPS6DtqHZTXGNuYM8NcHn4xUIX5GwlsS6Mfo2tDMcX83w1Jv0BuImfcUMl6jvYCzcpEdGENYHWisIvQLSlAK6UEIYGeG8CH/iRqRPQIrOW49EQJYlW2VSLuTf8SA6c9Z2xdSIsli9JOfr79VUdYpgrdiv7vFjiX5d+hcJVC0rjQkF6XlAWVH5yMfpr1OXFbpKqILygx9Zcj7IhMHodQsjtr6+FjIs5Xm5Nt1nY9Cpke/q3lHcgq0PVgwvMPMhTOxfv6XoKQGmDTJWsmAP8n4BotZm7H2OlO29/zJnrgJ8+ZienkAX5s2cAaT16Kvw== akos@laptop"
  ];
}
