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
    sops.secrets."nix-builder/build-host/private_key" = {};
    # remote build
    #nix.buildMachines = [
    #  {
    #    sshUser = "builder";
    #    hostName = "localhost";
    #    #system = "x86_64-linux";
    #    protocol = "ssh-ng";
    #    # if the builder supports building for multiple architectures,
    #    # replace the previous line by, e.g.
    #    systems = ["x86_64-linux" "aarch64-linux"];
    #    maxJobs = 30;
    #    speedFactor = 2;
    #    supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
    #    mandatoryFeatures = [];
    #    sshKey = config.sops.secrets."nix-builder/build-host/private_key".path;
    #  }
    #];

    nix.sshServe = {
      enable = true;
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPP+EWsn2LyMLqTuUUa6+o/toTgWWIZLsk4xG3shyyx nix-builder"
      ];
      protocol = "ssh-ng";
      write = true;
    };

    nix.distributedBuilds = true;
    # optional, useful when the builder has a faster internet connection than yours
    nix.extraOptions = ''
      builders-use-substitutes = true
    '';
  };
}
