{config, pkgs, options, lib, ... }:
{

    options = {
        bluetooth.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable bluetooth support";
        };
    };

        config = lib.mkIf config.bluetooth.enable {
            services.blueman.enable = true;
            hardware.bluetooth.enable = true;


            environment.systemPackages = with pkgs; [
                bluez
                    bluez-tools
            ];
        };
    }
