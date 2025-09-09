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
    programs.waybar.enable = true;
    #programs.waybar.settings.mainBar.layer = "top";
    #programs.waybar.systemd.enable = true;
    #programs.niri.settings.environment."NIXOS_OZONE_WL" = "1";
    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    environment.systemPackages = with pkgs; [
      wireplumber
      niri
      wofi
      swaylock
      waybar
      wl-clipboard
      mako
      fuzzel
    ];
  };
}
