{
  config,
  pkgs,
  lib,
  ...
}: {
  # steam
  options = {
    MODULES.games.steam.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable steam";
    };
  };

  config = lib.mkIf config.MODULES.games.steam.enable {
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
    };
  };
}
