{
  config,
  lib,
  pkgs,
  nixOpenClaw,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.MODULES.services.openclaw;
in {
  options.MODULES.services.openclaw = {
    enable = mkEnableOption "OpenClaw gateway wrapper (config/enable)";

    configPath = mkOption {
      type = types.str;
      default = "/etc/openclaw/openclaw.json";
      description = "Config path for OpenClaw gateway.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/openclaw";
      description = "OpenClaw state directory.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional token file for Telegram bot token configuration.";
    };
  };

  config = mkIf cfg.enable {
    services.openclaw-gateway = {
      enable = true;
      package =
        if pkgs ? openclaw-gateway
        then pkgs.openclaw-gateway
        else if pkgs ? openclaw
        then pkgs.openclaw
        else nixOpenClaw.packages.x86_64-linux.openclaw-gateway;
      stateDir = cfg.stateDir;
      configPath = cfg.configPath;
      # config = cfg.config;
      environmentFiles = lib.optional (cfg.environmentFile != null) (toString cfg.environmentFile);
      # maybe extra envs can be patched in by services.openclaw-gateway.environment.
    };

    # services.openclaw-gateway.package = nixOpenClaw.packages.x86_64-linux.openclaw-gateway;
    # services.openclaw-gateway.stateDir = "/var/lib/openclaw";
    # services.openclaw-gateway.configPath = "/etc/openclaw/openclaw.json";

    nixpkgs.overlays = [
      nixOpenClaw.overlays.default
    ];
    services.openclaw-gateway.config = {
      gateway = {
        mode = "local";
        auth = {
          token = "CHANGE_ME_OPENCLAW_GATEWAY_TOKEN_";
        };
      };

      plugins = [
        "opencode-gemini-auth@latest"
        "copilot-proxy"
      ];

      # channels.telegram = {
      #   tokenFile = "/home/akos/.secrets/openclaw-telegram-token";
      #   allowFrom = [0];
      #   groups = {
      #     "*" = {requireMention = true;};
      #   };
      # };
    };
    # environment.etc."openclaw/openclaw.json" = {
    #   source = pkgs.writeText "openclaw.json" ''
    #     {
    #       "gateway": {
    #         "mode": "local",
    #         "auth": {
    #           "token": "CHANGE_ME_OPENCLAW_GATEWAY_TOKEN"
    #         }
    #       }
    #     }
    #   '';
    # };

    # OpenClaw CLI tools
    environment.systemPackages = [
      (
        if pkgs ? openclaw
        then pkgs.openclaw
        else null
      )
      (
        if pkgs ? openclaw-gateway
        then pkgs.openclaw-gateway
        else null
      )
      pkgs.github-copilot-cli
    ];

    users.groups.openclaw = {};
  };
}
