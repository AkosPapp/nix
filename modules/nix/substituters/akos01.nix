{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.akos01.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.akos01.enable {
    nix = {
      settings = {
        substituters = [
          "http://akos01.tail546fb.ts.net:5000?priority=50"
        ];
        trusted-substituters = [
          "http://akos01.tail546fb.ts.net:5000?priority=50"
        ];
        trusted-public-keys = [
          "akos01.tail546fb.ts.net:sLx+ag0KitVYyMj8GVwO99o58QXWZRRXbDp6YSecrmc="
        ];
      };
    };
  };
}
