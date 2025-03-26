{
  pkgs,
  config,
  lib,
  sops,
  ...
}: {
  options = {
    MODULES.nix.builders.build-host = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Build Host on this machine";
    };
  };

  config = lib.mkIf config.MODULES.nix.builders.build-host.enable {
    #sops.secrets."nix-builder/owncloud/private_key" = {};
    #sops.secrets."nix-builder/owncloud/public_key" = {};

    #users.users.builder = {
    #  isNormalUser = true;
    #  description = "Nix Builder User";
    #  extraGroups = ["wheel"];
    #  #openssh.authorizedKeys.keyFiles = [config.sops.secrets."nix-builder/owncloud/public_key".path];
    #};

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
    #    #sshKey = config.sops.secrets."nix-builder/owncloud/private_key".path;
    #  }
    #];
  };
}
