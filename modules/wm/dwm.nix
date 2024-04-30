{ config, pkgs, lib, ... }: {
  options = {
    MODULES.wm.dwm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the dwm window manager.";
    };
  };

  config = lib.mkIf config.MODULES.wm.dwm.enable {
    services.xserver.windowManager.dwm.package = pkgs.dwm.overrideAttrs {
      src = # /home/akos/Programs/dwm-flexipatch;
        pkgs.fetchFromGitHub {
          owner = "PPAPSONKA";
          repo = "dwm";
          rev = "d0e8c140b7464f9be3ee28a8c720de72a9f7103f";

          sha256 = "sha256-ZQsEmi0+exI5to28gDQDj51s/KghgFrfFM9iEcA2Za4=";

        };
    };
    #nixpkgs.overlays = [
    #    (final: prev: {
    #    dwm = prev.dwm.overrideAttrs (old: { src = ./dwm ;});
    #    })
    #];
    environment.systemPackages = with pkgs; [
      dmenu
      dunst
      dwmblocks
      kitty
      libnotify
      rofi
      sxhkd
      wmctrl
      xdotool
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
    programs.slock.enable = true;
  };
}
