{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  nixos-version,
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
      kitty
      neovim
      gnumake
    ];
    users.mutableUsers = false;
    nix.settings.experimental-features = ["nix-command" "flakes"];

    nix.gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 7d";
      persistent = true;
    };
    programs.mosh.enable = true;

    system.stateVersion = nixos-version;
  };
}
