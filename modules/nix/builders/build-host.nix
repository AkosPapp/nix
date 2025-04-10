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
    sops.secrets."nix-builder/private_key" = {};
    #nix.buildMachines = [
    #  {
    #    sshUser = "builder";
    #    hostName = "localhost";
    #    #system = "x86_64-linux";
    #    protocol = "ssh-ng";
    #    # if the builder supports building for multiple architectures,
    #    # replace the previous line by, e.g.
    #    systems = ["x86_64-linux" "aarch64-linux"];
    #    maxJobs = 16;
    #    speedFactor = 2;
    #    supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
    #    mandatoryFeatures = [];
    #    sshKey = config.sops.secrets."nix-builder/private_key".path;
    #  }
    #];

    users.users.builder = {
      createHome = true;
      home = "/var/builder";
      isNormalUser = true;
      extraGroups = ["nixbld" "wheel"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAuOKEh8UO6InEyDHU+bZAR+WwPoy/NM5sX6RpEmDOXp root@legion5"
      ];
      group = "users";
    };

    services.nix-serve = {
      enable = true;
      secretKeyFile = "/var/cache-priv-key.pem";
    };
    nix = {
      settings = {
        trusted-users = ["builder" "@nixbld" "root" "@root" "@wheel"];
      };
    };

    nix.distributedBuilds = true;
    # optional, useful when the builder has a faster internet connection than yours
    nix.extraOptions = ''
      builders-use-substitutes = true
    '';
  };
}
