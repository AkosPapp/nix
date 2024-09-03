{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
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
      gnumake
      kitty
      htop-vim

      # nvim
      pkgs-unstable.neovim
      xclip
      tree-sitter
      lua-language-server
      cmake-language-server
      lldb
      gdb
      nil
      nixd
      valgrind
      nodejs_18
      shellcheck

      # git
      gitFull
    ];
                permittedInsecurePackages = [
                "electron-27.3.11"
              ];
    users.mutableUsers = true;
    nix.settings.experimental-features = ["nix-command" "flakes"];
  };
}
