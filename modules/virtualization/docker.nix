{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.virtualisation.docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Docker support";
    };
  };

  config = lib.mkIf config.MODULES.virtualisation.docker.enable {
    virtualisation.docker = {
      enable = true;
      rootless.enable = true;
    };
    environment.systemPackages = with pkgs; [docker-compose];
  };
}
