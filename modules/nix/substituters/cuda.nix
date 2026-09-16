{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.cuda.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.cuda.enable {
    nix = {
      settings = {
        trusted-substituters = ["https://cache.nixos-cuda.org"];
        substituters = ["https://cache.nixos-cuda.org"];
        trusted-public-keys = ["cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="];
      };
    };
  };
}
