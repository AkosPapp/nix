{ config, pkgs, lib, ... }: {
  options = {
    MODULES.fonts.nerdfonts.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.fonts.nerdfonts.enable {
    fonts.packages = with pkgs; [ jetbrains-mono nerdfonts ];

    environment.systemPackages = with pkgs; [ fontconfig ];
  };
}
