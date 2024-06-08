{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.system.sound.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sound support";
    };
  };
  config = lib.mkIf config.MODULES.system.sound.enable {
    sound.enable = true;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };

    environment.systemPackages = with pkgs; [
      pavucontrol
      pulsemixer
      easyeffects
      qpwgraph
    ];
  };
}
