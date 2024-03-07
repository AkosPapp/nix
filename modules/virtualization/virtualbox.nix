{config, pkgs, options, lib, ... }:
{
    options = {
        virtualisation.virtualbox.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable VirtualBox";
        };
    };

    config = lib.mkIf config.virtualisation.virtualbox.enable {
        virtualisation.virtualbox.host.enable = true;
        virtualisation.virtualbox.host.enableExtensionPack = true;
    };
}
