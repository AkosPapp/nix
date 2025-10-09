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
    #programs.waybar.enable = true;
    programs.xwayland.enable = true;
    #programs.waybar.settings.mainBar.layer = "top";
    #programs.waybar.systemd.enable = true;
    #programs.niri.settings.environment."NIXOS_OZONE_WL" = "1";
    environment.sessionVariables.NIXOS_OZONE_WL = "1";
    environment.sessionVariables.ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    environment.sessionVariables.OZONE_PLATFORM = "wayland";
    services.upower.enable = true;

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-gnome
      wireplumber
      niri
      swww
      wofi
      hyprlock
      waybar
      wl-clipboard
      mako
      fuzzel
      xwayland-satellite
    ];

    # PipeWire (required for screencasting)
    services.pipewire = {
      enable = lib.mkForce true;
      audio.enable = true; # If you want audio support
      pulse.enable = true; # PulseAudio compatibility
      jack.enable = false; # Set true only if you need JACK
      alsa.enable = true;
      alsa.support32Bit = true; # For 32-bit app support
      wireplumber.enable = true;
      socketActivation = true; # Recommended for modern setups
      systemWide = false; # Should be false (per-user is safer)
    };

    # RTKit for real-time priority (recommended for PipeWire)
    security.rtkit.enable = true;

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
          default = lib.mkForce ["gnome"];
        };
        niri = {
          default = lib.mkForce ["gnome" "gtk"];
          "org.freedesktop.impl.portal.ScreenCast" = ["gnome"];
          "org.freedesktop.impl.portal.RemoteDesktop" = ["gnome"];
        };
      };
    };

    # Hardware audio support
    hardware.alsa.enable = true; # Usually enabled by default
  };
}
