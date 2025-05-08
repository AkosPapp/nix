{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.system.gpg.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable GnuPG";
    };
  };

  config = lib.mkIf config.MODULES.system.gpg.enable {
    environment.systemPackages = with pkgs; [
      gnupg
      gpgme
      pinentry-tty
      pinentry-qt
      pinentry-all
      pinentry-rofi
    ];
    services.dbus.packages = with pkgs; [gcr];
    services.pcscd.enable = true;
    programs.mtr.enable = true;
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };
}
