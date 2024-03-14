{config, pkgs, lib, ... }:
{
    options = {
        MODULES.wm.dwm.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the dwm window manager.";
        };
    };

    config = lib.mkIf config.MODULES.wm.dwm.enable {
        services.xserver.windowManager.dwm.package = pkgs.dwm.overrideAttrs {
            src = /home/akos/Programs/dwm-flexipatch;
        };
        #nixpkgs.overlays = [
        #    (final: prev: {
        #    dwm = prev.dwm.overrideAttrs (old: { src = ./dwm ;});
        #    })
        #];
        environment.systemPackages = with pkgs; [
            sxhkd
                rofi
                libnotify
                dunst
                dwmblocks
                wmctrl
                xdotool
                dmenu
                rofi
                xorg.libXi
                xorg.libXinerama
                xorg.libXrender
                xorg.libXtst
                xorg.libxcb
                xorg.xev
                xorg.xhost
                xorg.xinit
                xorg.xmodmap
                xorg.xrdb
        ];

        services.xserver.enable = true;
        services.picom.enable = true;
        services.xserver.windowManager.dwm.enable = true;
        MODULES.wm.dwmblocks.enable = true;
        programs.slock.enable = true;

    };
}
