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
      dates = "daily";
      options = "--delete-older-than 7d";
      persistent = true;
    };
    systemd.services.nix-gc = {
      # ... existing options ...
      after = ["default.target"];
      wantedBy = [];
    };
  };
}
