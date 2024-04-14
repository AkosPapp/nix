{ pkgs-unstable, ... }: {
  colorschemes = {
    dracula = {
      enable = false;
      highContrastDiff = true;
      fullSpecialAttrsSupport = true;
    };
    base16.package = pkgs-unstable.vimPlugins.base16-nvim;
    base16.defaultPackage = pkgs-unstable.vimPlugins.base16-nvim;
  };
}
