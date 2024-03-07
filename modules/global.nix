{ config, lib, pkgs, ... }:
{
    networking.firewall.enable = true;
    environment.systemPackages = with pkgs; [
        vim
            git
    ];
}
