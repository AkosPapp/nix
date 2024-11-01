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
      description = "Admin user for Servers";
    };
  };

  config = lib.mkIf config.USERS.nix-builder.enable {
    users.groups.nix-builder = {};
    users.users.nix-builder = {
      isSystemUser = true;
      description = "nix-builder";
      group = "nix-builder";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOavECvlGNeGwEWZASDDjU7XCZOQkO2XU2Zm1VKFWMME nix-builder"
      ];
    };
  };
}
