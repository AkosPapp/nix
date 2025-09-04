{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.dev.platformio.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Nerd Fonts";
    };
  };

  config = lib.mkIf config.MODULES.dev.platformio.enable {
    services.udev.packages = with pkgs; [platformio-core.udev];
    environment.systemPackages = with pkgs; [platformio-core];
  };
}
