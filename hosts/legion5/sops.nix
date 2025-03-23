{lib, ...}: {
  sops = {
    defaultSopsFile = /sops/secrets.yaml;
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
    secrets = {
      example_key = {};
    };
  };
}
