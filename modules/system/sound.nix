{config, pkgs, lib, ... }:
{
# Enable sound with pipewire.
    config = lib.mkIf config.sound.enable {
        #hardware.pulseaudio.enable = false;
        security.rtkit.enable = true;
        services.pipewire = {
            enable = true;
            alsa.enable = true;
            alsa.support32Bit = true;
            pulse.enable = true;
            jack.enable = true;
        };

        environment.systemPackages = with pkgs; [
            pavucontrol
                pulsemixer
                easyeffects
                qpwgraph
        ];
    };
}
