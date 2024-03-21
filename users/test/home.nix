{ config, pkgs, lib, nixvim, pkgs-unstable, ... }: {

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "test";
  home.homeDirectory = "/home/test";

  programs = {
    zsh = {
      enable = true;
      autocd = true;
      #autosuggestion = {
      #    enable = true;
      #};
    };
    git = {
      enable = true;
      userName = "Papp Akos";
      userEmail = "qq557703@gmail.com";
      lfs.enable = true;
    };
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
