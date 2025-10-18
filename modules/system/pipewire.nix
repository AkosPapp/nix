{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.system.pipewire.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable sound support";
    };
  };
  config = lib.mkIf config.MODULES.system.pipewire.enable {
    security.rtkit.enable = true;

    # PipeWire (required for screencasting)
    services.pipewire = {
      enable = true;
      alsa.support32Bit = true; # For 32-bit app support
      wireplumber.enable = true;
      socketActivation = true; # Recommended for modern setups
      systemWide = false; # Should be false (per-user is safer)
    };

    environment.systemPackages = with pkgs; [
      wireplumber
      pavucontrol
      pulsemixer
      easyeffects
      qpwgraph
    ];
  };
}
