{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.virtualisation.podman.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Podman support";
    };
  };

  config = lib.mkIf config.MODULES.virtualisation.podman.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
    };
    environment.systemPackages = with pkgs; [podman-compose podman-tui];
  };
}
