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
      pulse.enable = true; # For PulseAudio app support
      jack.enable = true; # For JACK app support
      alsa.enable = true; # For ALSA app support
      alsa.support32Bit = true; # For 32-bit app support
      wireplumber.enable = true;
      socketActivation = true; # Recommended for modern setups
      systemWide = false; # Should be false (per-user is safer)

      wireplumber.extraConfig."51-disable-mic-agc" = {
        "monitor.alsa.rules" = [
          {
            matches = [{"node.name" = "~alsa_input.*";}];
            actions.update-props = {
              # Keep mic gain fixed in software instead of syncing to the
              # hardware capture register, which some codecs auto-adjust
              # (drop in volume on loud input, requiring manual reset).
              "api.alsa.soft-mixer" = true;
            };
          }
        ];
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
