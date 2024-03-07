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
        resolvconf = {
            enable = true;
        };
	nameservers = [
		"100.100.100.100"
		"9.9.9.9"
		"1.1.1.1"
	];
    };

    services.xserver.enable = false;
    boot.plymouth.enable = false;
    sound.enable = false;

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


    services.ssh.enable = true;
    services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
    virtualisation.docker.enable = true;
    services.tailscale.enable = true;

    system.stateVersion = "23.11";

}

