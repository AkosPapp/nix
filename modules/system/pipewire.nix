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
      extraConfig.pipewire = {
        "10-f64-processing" = {
          "context.properties" = {
            # Internal PipeWire clock and processing format
            "default.clock.rate" = 48000;
            "default.clock.allowed-rates" = [44100 48000 96000];
            "default.clock.format" = "F64";

            # Optional tuning for latency and buffer sizing
            "default.clock.quantum" = 1024;
            "default.clock.min-quantum" = 32;
            "default.clock.max-quantum" = 8192;
          };
        };
      };
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
