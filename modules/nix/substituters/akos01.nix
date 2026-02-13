{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.akos01.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable akos01.airlab substituter";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.akos01.enable {
    nix = {
      settings = {
        substituters = [
          "http://akos01.airlab:5000"
        ];
        trusted-substituters = [
          "http://akos01.airlab:5000"
        ];
        trusted-public-keys = [
          "akos01.airlab:xT0wS6R0UZTtPqVNVb9boPkSfxAf47uS8zEEnzFgfkk="
        ];
      };
    };
  };
}
