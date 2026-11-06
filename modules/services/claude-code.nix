# Claude Code (`claude`) pointed at the fleet's OmniRoute gateway - the
# Anthropic-wire twin of modules/services/pi.nix / opencode.nix.
#
# Why env and not a config file: Claude Code takes its endpoint and credential
# entirely from the environment (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN,
# documented in the module options below), so a package wrapper that exports
# them from the sops mounts at exec keeps the key out of the store AND out of
# every settings file - the piWrapper doctrine. OmniRoute answers the
# Anthropic wire (POST /v1/messages probed live 2026-11-05: real Anthropic
# completions, x-api-key and Authorization: Bearer both accepted), so one
# base URL fronts every subscription model.
#
# What the wrapper deliberately does NOT fix in place:
#   * Onboarding/telemetry/trust prompts are per-user state in ~/.claude.json.
#     A tmpfiles `f` rule seeds hasCompletedOnboarding for NEW users only (f
#     never touches an existing file), so an already-onboarded home is left
#     completely alone.
#   * The nixpkgs wrapper already exports DISABLE_AUTOUPDATER=1 (store is
#     read-only anyway); this wrapper adds DISABLE_NONESSENTIAL_TRAFFIC +
#     DISABLE_AUTOUPDATER defensively and the model-role pins.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    literalExpression
    types
    ;

  cfg = config.MODULES.services.claudeCode;

  catalog = config.MODULES.services.modelCatalog.models;

  # The wrapper: endpoint + key + role pins exported at exec (see header).
  # BASE_URL is the ORIGIN, no /v1 - Claude Code appends /v1/messages itself
  # (measured legion5 2026-11-05: a base URL with a trailing /v1 gets the
  # suffix doubled and 404s). The role names follow Claude Code's own model
  # picker: ANTHROPIC_MODEL is the default, the *_MODEL trio is what
  # /model's Opus/Sonnet/Haiku options resolve to when behind a proxy.
  claudeWrapper = pkgs.writeShellScriptBin "claude" ''
    export ANTHROPIC_BASE_URL="${cfg.baseUrl}"
    export ANTHROPIC_AUTH_TOKEN="$(cat ${config.sops.secrets.${cfg.apiKeySecret}.path} 2>/dev/null || true)"
    export ANTHROPIC_MODEL="${cfg.defaultModel}"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${cfg.opusModel}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${cfg.sonnetModel}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${cfg.haikuModel}"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${
      if cfg.minimalTraffic
      then "1"
      else "0"
    }"
    export DISABLE_AUTOUPDATER=1
    exec ${cfg.package}/bin/claude "$@"
  '';

  # Minimal onboarding seed (tmpfiles `f`: written only where the user has no
  # ~/.claude.json yet - see header).
  onboardingSeed = pkgs.writeText "claude-onboarding.json" (
    builtins.toJSON {
      hasCompletedOnboarding = true;
    }
  );
in {
  options.MODULES.services.claudeCode = {
    enable = mkEnableOption ''
      Claude Code wired to the OmniRoute gateway: a claude wrapper exports
      ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN (from the sops mount) and the
      model-role pins at exec, and new users get an onboarding-complete seed.
      OmniRoute answers the Anthropic wire, so no sidecar or translation hop
      is involved.
    '';

    package = mkOption {
      type = types.package;
      default = pkgs-unstable.claude-code;
      defaultText = literalExpression "pkgs-unstable.claude-code";
      description = "claude-code package the wrapper execs (its own bin/claude is the nixpkgs update-disabled wrapper).";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users to seed ~/.claude.json onboarding state for (the wrapper is system-wide regardless).";
    };

    baseUrl = mkOption {
      type = types.str;
      default = "https://omniroute.hp";
      example = "https://ddg-gw.internal";
      description = "Anthropic-wire origin WITHOUT a /v1 suffix (Claude Code appends /v1/messages itself); the gateway is expected to speak that wire.";
    };

    apiKeySecret = mkOption {
      type = types.str;
      default = "omniroute_api_key";
      example = "anthropic_api_key";
      description = "sops secret name mounted and exported as ANTHROPIC_AUTH_TOKEN by the wrapper.";
    };

    defaultModel = mkOption {
      type = types.str;
      default = "antigravity/claude-opus-4-6-thinking";
      example = "openrouter/anthropic/claude-sonnet-4.5";
      description = "ANTHROPIC_MODEL pin - a model id as the GATEWAY spells it (gateway connection prefix included).";
    };

    opusModel = mkOption {
      type = types.str;
      default = cfg.defaultModel;
      defaultText = literalExpression "MODULES.services.claudeCode.defaultModel";
      description = "What the picker's Opus tier resolves to behind the gateway.";
    };

    sonnetModel = mkOption {
      type = types.str;
      default = "antigravity/claude-sonnet-4-6";
      description = "What the picker's Sonnet tier resolves to behind the gateway.";
    };

    haikuModel = mkOption {
      type = types.str;
      default = "ddgw/claude-haiku-4-5";
      description = ''
        What the picker's Haiku tier resolves to behind the gateway. The
        auto/claude-haiku id is the cheapest, but its kilocode connection
        burned its credits (402 measured 2026-11-05), so the dvgw connection
        fronts the pin by default.
      '';
    };

    minimalTraffic = mkOption {
      type = types.bool;
      default = true;
      description = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: suppress statsig/telemetry/update pings (fleet privacy posture; the gateway already sees everything that matters).";
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted API-key secret; doctrine in modules/services/pi.nix. The omniroute key mount is shared with pi/opencode/omp/kilo/cline, so this must match what those modules declare on the host.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted API-key secret. The claude wrapper cats the mount AS THE INVOKING USER, so it must be group-readable by exactly those users (the pi/opencode mount group on this fleet).";
    };
  };

  config = mkIf cfg.enable {
    # The wrapper reads the key file as the INVOKING user, so the mount must
    # be group-readable by exactly the users listed - same trap as pi.nix:
    # an unreadable mount silently exports an empty token (401 on the wire).
    assertions = [
      {
        assertion = cfg.users == [] || cfg.secretGroup == "users";
        message = ''
          MODULES.services.claudeCode.secretGroup is "${cfg.secretGroup}" but
          MODULES.services.claudeCode.users is non-empty: the claude wrapper runs as those
          users and would cat an unreadable mount (empty ANTHROPIC_AUTH_TOKEN,
          401). Use group "users" (the pi/opencode mount group on this fleet).
        '';
      }
      {
        # Same secret name as the pi/opencode/omp mounts: sops-nix mounts each
        # name with one owner, so the modules may not disagree.
        assertion =
          !config.MODULES.services.pi.enable
          || cfg.secretOwner
          == config.MODULES.services.pi.secretOwner
          && cfg.secretGroup == config.MODULES.services.pi.secretGroup;
        message = "MODULES.services.claudeCode.secretOwner/secretGroup must match MODULES.services.pi's (both mount ${cfg.apiKeySecret}).";
      }
    ];

    sops.secrets.${cfg.apiKeySecret} = {
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
    };

    environment.systemPackages = [claudeWrapper];

    # Seed onboarding for users who have never run claude (f = create-if-
    # missing, never overwrite - see the module header).
    systemd.tmpfiles.rules =
      map (
        u: "f ${config.users.users.${u}.home}/.claude.json 0600 ${u} ${config.users.users.${u}.group} - ${onboardingSeed}"
      )
      cfg.users;
  };
}
