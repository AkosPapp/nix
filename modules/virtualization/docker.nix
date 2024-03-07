{config, pkgs, lib, ... }:
{
    config = lib.mkIf config.virtualisation.docker.enable {

        environment.systemPackages = with pkgs; [
            docker-compose
        ];
    };
}
