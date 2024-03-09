{ config, lib, pkgs, ... }:
{
    imports = [
        ./hardware-configuration.nix
    ];


    networking = {
        hostName = "server1";
        hostId = "007f0200";
        interfaces = {
            enp3s0.ipv4.addresses = [{
                address = "10.1.1.1";
                prefixLength = 8;
            }];
        };
        defaultGateway = {
            address = "10.0.0.1";
            interface = "enp3s0";
        };
        #resolvconf = {
        #    enable = true;
        #};
    };


    environment.systemPackages = with pkgs; [
        vim 
            wget
            tmux
    ];


# garbage cleaning
    nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
    };


    MODULES.virtualisation.docker.enable = true;
    USERS.admin.enable = true;

    system.stateVersion = "23.11";

}

