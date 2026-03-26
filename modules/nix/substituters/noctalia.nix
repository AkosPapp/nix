{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.noctalia.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable noctalia substituter";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.noctalia.enable {
    nix.settings = {
      extra-substituters = ["https://noctalia.cachix.org"];
      extra-trusted-public-keys = ["noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="];
    };
  };
}
