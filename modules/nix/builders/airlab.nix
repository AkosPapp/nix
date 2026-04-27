{
  lib,
  config,
  ...
}: {
  options = {
    MODULES.nix.builders.airlab = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Airlab builders";
    };
  };

  config = lib.mkIf config.MODULES.nix.builders.airlab {
    MODULES.security.sops.enable = true;
    sops.secrets."nix-builder/private_key" = {
      mode = "0400";
      owner = "root";
      group = "root";
      path = "/root/.ssh/id_ed25519";
    };

    # remote build
    nix.buildMachines = [
      {
        sshUser = "builder";
        hostName = "r4unb02.airlab";
        #system = "x86_64-linux";
        protocol = "ssh-ng";
        # if the builder supports building for multiple architectures,
        # replace the previous line by, e.g.
        systems = ["x86_64-linux" "aarch64-linux"];
        maxJobs = 60;
        speedFactor = 2;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        mandatoryFeatures = [];
        sshKey = config.sops.secrets."nix-builder/private_key".path;
      }
    ];
    nix.distributedBuilds = true;
    # optional, useful when the builder has a faster internet connection than yours
    nix.extraOptions = ''
      builders-use-substitutes = true
    '';
  };
}
