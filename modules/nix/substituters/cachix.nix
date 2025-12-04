{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.cachix.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.cachix.enable {
    nix = {
      settings = {
        substituters = [
          "https://nix-community.cachix.org"
        ];
        trusted-substituters = [
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
    };
  };
}
