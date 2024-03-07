{config, pkgs, lib, ... }:
{
    options = {
        programs.dwm.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the dwm window manager.";
        };
    };

    config = lib.mkIf config.programs.dwm.enable {
        nixpkgs.overlays = [
# dwm-flexipatch
            (final: prev: {
             dwm = prev.dwm.overrideAttrs (old: { src = /home/akos/Programs/dwm-flexipatch ;});
             })
        ];
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

# Enable the X11 windowing system.
        services.xserver.enable = true;
        services.picom.enable = true;

# display manager
        services.xserver.windowManager.dwm.enable = true;
        programs.dwmblocks.enable = true;
        programs.slock.enable = true;

    };
}
