{config, pkgs, options, lib, ... }:
{
    options = {
        MODULES.virtualisation.virtualbox.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable VirtualBox";
        };
    };

    config = lib.mkIf config.MODULES.virtualisation.virtualbox.enable {
        virtualisation.virtualbox.host.enable = true;
        virtualisation.virtualbox.host.enableExtensionPack = true;
    };
}
