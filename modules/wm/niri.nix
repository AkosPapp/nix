{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.wm.niri.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the niri window manager.";
    };
  };

  config = lib.mkIf config.MODULES.wm.niri.enable {
    programs.niri.enable = true;
    environment.systemPackages = with pkgs; [
      niri
      wofi
      swaylock
      waybar
      wl-clipboard
    ];
  };
}
