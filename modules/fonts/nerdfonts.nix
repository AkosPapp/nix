{config, pkgs, lib, ... }:
{
    options = {
        fonts.nerdfonts.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable Nerd Fonts";
        };
    };

    config = lib.mkIf config.fonts.nerdfonts.enable {
        fonts.packages = with pkgs; [
            jetbrains-mono
                nerdfonts
        ];

        environment.systemPackages = with pkgs; [
            fontconfig
        ];
    };
}
