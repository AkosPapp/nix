{config, pkgs, lib, ... }:
{
# steam
    config = lib.mkIf config.programs.steam.enable {

        programs.steam = {
            remotePlay.openFirewall = true;
            dedicatedServer.openFirewall = true;
        };

    };
}
