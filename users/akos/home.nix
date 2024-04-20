{ config, pkgs, lib, pkgs-unstable, my-nixvim, system, ... }: {

# Home Manager needs a bit of information about you and the
# paths it should manage.
    home.username = "akos";
    home.homeDirectory = "/home/akos";
    home.packages = [ my-nixvim.packages.${system}.default ];

    programs = {
        zsh = {
            enable = false;
            autocd = true;
#autosuggestion = {
#    enable = true;
#};
        };
        git = {
            enable = false;
            userName = "Papp Akos";
            userEmail = "qq557702@gmail.com";
            lfs.enable = true;
        };
    };
    services.dwm-status = { 
        enable = true;
        order = ["battery"];
        #order = ["audio" "backlight" "battery" "cpu_load" "network" "time"];
        extraConfig = {
            separator = " | ";

            battery = {
                notifier_levels = [ 2 5 10 15 20 ];
            };

            time = {
                format = "%H:%M";
            };
        } ;
    };
# This value determines the Home Manager release that your
# configuration is compatible with. This helps avoid breakage
# when a new Home Manager release introduces backwards
# incompatible changes.

# You can update Home Manager without changing this value. See
# the Home Manager release notes for a list of state version
# changes in each release.
    home.stateVersion = "23.11";

# Let Home Manager install and manage itself.
    programs.home-manager.enable = true;
                                                              }
