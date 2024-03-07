{config, pkgs, options, lib, ... }:
{
    options = {
        programs.gpg.enable = lib.mkOption {
            type = with lib.types; bool;
            default = true;
            description = "Enable GnuPG";
        };
    };

    config = lib.mkIf config.programs.gpg.enable {
        services.dbus.packages = with pkgs; [
            pass-secret-service
                gcr
        ];
        services.pcscd.enable = true;
        programs.mtr.enable = true;
        programs.gnupg.agent = {
            enable = true;
            pinentryFlavor = "gtk2";
            enableSSHSupport = true;
        };
    };
}
