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
    };
    environment.systemPackages = with pkgs; [docker-compose];

    virtualisation.docker = {
      #daemon.settings = {
      #  bip = "172.1.1.1/16";
      #  default-address-pools = [
      #    {
      #      base = "172.1.0.0/16";
      #      size = 16;
      #    }
      #  ];
      #};
    };
  };
}
