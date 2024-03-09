{config, pkgs, lib, ... }:
{
    options = {
        PROFILES.global.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable global profile";
        };
    };

    config = lib.mkIf config.PROFILES.global.enable {
        MODULES = {
            networking.sshd.enable = true;
            networking.tailscale.enable = true;
            system.locale.enable = true;
        };
        environment.systemPackages = with pkgs; [
            neovim
                git
                gnumake
                kitty
                htop-vim
        ];
        users.mutableUsers = false;

        nixpkgs.config.permittedInsecurePackages = [
            "nix-2.16.2"
        ];
    };

}
