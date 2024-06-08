{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.system.locale.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the system locale configuration.";
    };
  };

  config = lib.mkIf config.MODULES.system.locale.enable {
    time.timeZone = "Europe/Vienna";

    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    services.xserver.xkb = {layout = "at";};
  };
}
