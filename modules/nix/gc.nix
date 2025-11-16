{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.nix.gc.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.nix.gc.enable {
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 1m";
      persistent = true;
    };
    systemd.services.nix-gc = {
      after = ["default.target"];
      wantedBy = [];
    };
  };
}
