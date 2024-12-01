{
  my-nixvim,
  system,
  nixos-version,
  ...
}: {
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "akos";
  home.homeDirectory = "/home/akos";
  home.packages = [my-nixvim.packages.${system}.default];

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
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  gtk.font.size = 18;

  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = nixos-version;

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
