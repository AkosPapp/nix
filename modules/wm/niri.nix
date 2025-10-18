{
  config,
  pkgs,
  lib,
  niri,
  ...
}: {
  options = {
    MODULES.wm.niri.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the niri window manager.";
    };
  };

  imports = [niri.nixosModules.niri];
  config = lib.mkIf config.MODULES.wm.niri.enable {
    nixpkgs.overlays = [niri.overlays.niri];

    niri-flake.cache.enable = true;
    programs.niri.package = pkgs.niri;
    programs.niri.enable = true;
    programs.xwayland.enable = true;
    environment.sessionVariables.NIXOS_OZONE_WL = "1";
    environment.sessionVariables.ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    environment.sessionVariables.OZONE_PLATFORM = "wayland";
    services.upower.enable = true;

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-gnome
      niri
      wdisplays
      wlr-randr
      xorg.xrandr
      swww
      wofi
      hyprlock
      waybar
      wl-clipboard
      mako
      fuzzel
      xwayland-satellite
    ];

    # PipeWire for screencasting
    MODULES.system.pipewire.enable = true;

    # D-Bus (should already be enabled by default on NixOS)
    services.dbus = {
      enable = true; # Usually implicit
      implementation = "broker"; # Default, can also be "dbus"
    };

    # XDG Desktop Portal for screencasting
    xdg.portal = {
      enable = true;
      wlr.enable = false; # Disable wlr portal to avoid conflicts
      extraPortals = [pkgs.xdg-desktop-portal-gnome];
      config = {
        common = {
          default = ["gnome"];
        };
        niri = {
          default = ["gnome" "gtk"];
          "org.freedesktop.impl.portal.ScreenCast" = ["gnome"];
          "org.freedesktop.impl.portal.RemoteDesktop" = ["gnome"];
        };
      };
    };
  };
}
