{
  lib,
  pkgs,
  pkgs-unstable,
  config,
  ...
}: {
  options = {
    MODULES.nix.builders.build-host = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Airlab builders";
    };
  };

  config = lib.mkIf config.MODULES.nix.builders.build-host {
    MODULES.security.sops.enable = true;
    sops.secrets."nix-builder/airlab/private_key" = {};
    # remote build
    nix.buildMachines = [
      {
        sshUser = "builder";
        hostName = "localhost";
        #system = "x86_64-linux";
        protocol = "ssh-ng";
        # if the builder supports building for multiple architectures,
        # replace the previous line by, e.g.
        systems = ["x86_64-linux" "aarch64-linux"];
        maxJobs = 30;
        speedFactor = 2;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        mandatoryFeatures = [];
        sshKey = config.sops.secrets."nix-builder/airlab/private_key".path;
      }
    ];

    users.users.builder = {
      isNormalUser = true;
      home = "/var/empty";
      createHome = false;
      extraGroups = ["nixbld"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE+c88YGotI3xhM2y8+RuUuVJD3sAt9jUtCaYEYJ1JHT akos@laptop"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCYoxGrmlgUcVfncMnlDONPk5RwSEqbiBpvT3c2m9MIDsYdYlLfnRN5YJPZgp8CHcPnPK2rboRiHAO00j545ci2CDeAp6zGKoOhX0q/3fES3ySqMG7lJ+cplxoXekSL9GNOQqSREDymqrMfqGy9OnupqcAZForX/k1aegi99TgZwbGMAK/UIzfdkQr49VVzYbaNR14rikIfjvi23s4bdP/KgeAs0T9KEKKSAd9WJQxUr/dmTjNBODzW10llgmCCVRNk3Pj4A1qiGiz0wkjG7XmZT0QjHyrX2GzSYuhW1l8s6mY3tTBBKVoj+peBphgxGBbEwUCQh0yPVBGstM5fHqN1bvOjRfYNQboVSmLhicX7Bk0WNLPS6DtqHZTXGNuYM8NcHn4xUIX5GwlsS6Mfo2tDMcX83w1Jv0BuImfcUMl6jvYCzcpEdGENYHWisIvQLSlAK6UEIYGeG8CH/iRqRPQIrOW49EQJYlW2VSLuTf8SA6c9Z2xdSIsli9JOfr79VUdYpgrdiv7vFjiX5d+hcJVC0rjQkF6XlAWVH5yMfpr1OXFbpKqILygx9Zcj7IhMHodQsjtr6+FjIs5Xm5Nt1nY9Cpke/q3lHcgq0PVgwvMPMhTOxfv6XoKQGmDTJWsmAP8n4BotZm7H2OlO29/zJnrgJ8+ZienkAX5s2cAaT16Kvw== akos@laptop"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOavECvlGNeGwEWZASDDjU7XCZOQkO2XU2Zm1VKFWMME nix-builder"
      ];
    };

    nix.distributedBuilds = true;
    # optional, useful when the builder has a faster internet connection than yours
    nix.extraOptions = ''
      builders-use-substitutes = true
    '';
  };
}
