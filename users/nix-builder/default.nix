{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    USERS.nix-builder.enable = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = "user for remote nix builds";
    };
  };

  config = lib.mkIf config.USERS.nix-builder.enable {
    users.groups.nix-builder = {};
    users.users.nix-builder = {
      isNormalUser = true;
      description = "nix-builder";
      group = "nix-builder";
      home = /var/empty;
      createHome = false;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOavECvlGNeGwEWZASDDjU7XCZOQkO2XU2Zm1VKFWMME nix-builder"
      ];
    };
    services.nix-serve = {
      enable = true;
      secretKeyFile = "/var/cache-priv-key.pem";
    };
  };
}
