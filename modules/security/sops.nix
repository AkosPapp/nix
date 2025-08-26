{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.security.sops.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SOPS";
    };
  };

  config = lib.mkIf config.MODULES.security.sops.enable {
    sops = {
      defaultSopsFile = ../../sops/secrets.yaml;
      defaultSopsFormat = "yaml";
      validateSopsFiles = true;
      age = {
        # This will automatically import SSH keys as age keys
        sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        # This is using an age key that is expected to already be in the filesystem
        keyFile = "/var/lib/sops-nix/key.txt";
        # This will generate a new key if the key specified above does not exist
        generateKey = lib.mkForce true;
      };
    };
    fileSystems = lib.mkIf config.PROFILES.zroot.enable {
      "/sops" = {
        device = "zroot/persist/sops";
        fsType = "zfs";
      };
    };
  };
}
