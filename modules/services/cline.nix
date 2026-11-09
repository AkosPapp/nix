# Cline CLI (`cline`) with a declarative provider config - the Cline twin of
# modules/services/pi.nix. Cline's global CLI state lives under ~/.cline/data
# (CLINE_DATA_DIR relocates it) and its provider slot is
# data/settings/providers.json - shape verified empirically on legion5
# 2026-11-05 with `cline auth -p openai-compatible -k ... -b ... -m ...`:
#
#   { "version": 1, "lastUsedProvider": "<id>", "modes": {},
#     "providers": { "<id>": { "settings": { "provider", "apiKey", "model",
#                    "baseUrl" }, "updatedAt": ..., "tokenSource": "manual" } } }
#
# Design points:
#   * providers.json is an app-WRITTEN file (auth flows, model switches), so it
#     cannot be a store symlink - a root oneshot deep-merges the declared
#     fragment at activation, the exact twin of pi.nix's settings merge (user
#     providers survive, our named slot is re-asserted).
#   * The apiKey must be a LITERAL in the JSON. Cline documents a `file:`
#     indirection, but the CLI/-p flow (which runs the turn through the
#     --cline-hub-daemon child) sends it UNRESOLVED on the wire (legion5
#     2026-11-05: gateway answered "Invalid API key" for `file:/run/...` and
#     `file:///run/...`, and accepted the same key literal - the earlier
#     devbox "file: works" note was inconclusive: an unresolved `file:` string
#     and a resolved-but-wrong key produce the identical gateway error). An
#     echo-server capture of the actual POST proved the settings.apiKey string
#     is sent verbatim. So the merge unit reads the sops mount as root and
#     injects the key into the user's 0600 providers.json; the store-rendered
#     fragment under /etc stays keyless (placeholder token) for inspection.
#   * cline is a BUN-compiled binary (its own UA says bun/1.4.2): it ships
#     bun's bundled Mozilla roots and ignores NixOS's trust store, so the
#     fleet CA that signs omniroute.hp fails verification
#     ("unable to get local issuer certificate") until NODE_EXTRA_CA_CERTS
#     points at the CA bundle (SSL_CERT_FILE is NOT read; measured
#     legion5 2026-11-05). The module's wrapper exports it, and the hub daemon
#     cline spawns inherits it - without the env, the daemon started from a
#     bare shell keeps failing TLS.
#   * ONE openai-compatible slot exists per Cline config, and it is a slot -
#     so this module claims it for OmniRoute (the subscription pool: every
#     hosted model answers through one base URL). The futurelab endpoint has
#     no second slot to live in; harnesses that want it directly (pi, omp,
#     opencode, kilo) have their own two-provider configs.
#   * `cline -p ... --provider <id>` (legion5 2026-11-05) REBUILDS that id's
#     slot from CLI defaults (model gpt-4o, no apiKey/baseUrl) and persists
#     it, wiping what this module wrote until the next activation. Plain
#     `cline -p "..."` honours the stored slot - use that (and `--model` for
#     a one-off) instead of --provider.
#   * Model ids are spelled as OmniRoute answers them ("antigravity/claude-
#     sonnet-4-6", "antigravity/claude-opus-4-6-thinking") - the wire
#     spelling, gateway prefix included (pi.nix doctrine). The default avoids
#     openrouter/*: OmniRoute's openrouter key is capped at $1/day
#     (measured 2026-11-05), and cline's turns carry a ~23 KB system prompt,
#     so subscription-backed ids are the sane picks.
#
# nixpkgs' cline builds from the pinned nixpkgs-unstable input (a raw
# nixpkgs-unstable HEAD build hash-mismatched on 2026-11-05 - the pinned
# rev is the supported one).
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

  cfg = config.MODULES.services.cline;

  gatewayKeyPath = config.sops.secrets.${cfg.apiKeySecret}.path;

  # The keyless /etc fragment (placeholder token; the merge unit injects the
  # real key from the sops mount - see the header for why file: is out).
  settingsFragment = {
    version = 1;
    lastUsedProvider = "openai-compatible";
    providers = {
      openai-compatible = {
        settings = {
          provider = "openai-compatible";
          apiKey = "MODULES.services.cline-managed-key";
          model = cfg.defaultModel;
          baseUrl = cfg.baseUrl;
        };
        tokenSource = "manual";
      };
    };
  };

  # The wrapper: bun's TLS trust fix (see header). Env flows into the hub
  # daemon the CLI spawns, which is where model requests actually run. The
  # path is the GENERATED NixOS bundle (it carries the fleet CA that signs
  # omniroute.hp; the bare caCertificates package does not) - verified live
  # on legion5 2026-11-05 with cline's hub daemon reaching the gateway.
  clineWrapper = pkgs.writeShellScriptBin "cline" ''
    export NODE_EXTRA_CA_CERTS="''${NODE_EXTRA_CA_CERTS:-/etc/ssl/certs/ca-certificates.crt}"
    exec ${cfg.package}/bin/cline "$@"
  '';

  mergeScript = pkgs.writeShellScript "cline-settings-merge" ''
    set -eu
    ${lib.concatMapStringsSep "\n" (
        u: let
          home = config.users.users.${u}.home;
          group = config.users.users.${u}.group;
          dir = "${home}/.cline/data/settings";
          target = "${dir}/providers.json";
          mcpTarget = "${dir}/cline_mcp_settings.json";
        in ''
          # ${u}
          mkdir -p "${dir}"
          chown ${u}:${group} "${dir}"
          chmod 0700 "${dir}"
          tmp="$(mktemp)"
          key="$(cat ${gatewayKeyPath})"
          if [ -s "${target}" ] && ! ${pkgs.jq}/bin/jq -e . "${target}" >/dev/null 2>&1; then
            # Unparseable is not ours to interpret - keep it, start from the fragment.
            cp -f "${target}" "${target}.cline-nixos-backup"
            cp ${settingsFile} "$tmp"
          elif [ -s "${target}" ] && ${pkgs.jq}/bin/jq -s '((.[0] * .[1]) | .version = 1 | .lastUsedProvider = (.lastUsedProvider // "openai-compatible"))' "${target}" ${settingsFile} >"$tmp"; then
            :
          else
            cp ${settingsFile} "$tmp"
          fi
          # Re-assert the managed slot's literal key (the fragment carries a
          # placeholder; cline sends settings.apiKey verbatim - see header).
          ${pkgs.jq}/bin/jq --arg k "$key" '.providers["openai-compatible"].settings.apiKey = $k' "$tmp" >"$tmp.k" && mv "$tmp.k" "$tmp"
          if cmp -s "$tmp" "${target}" 2>/dev/null; then
            rm -f "$tmp"
          else
            install -m 0600 -o ${u} -g ${group} "$tmp" "${target}"
          fi
          rm -f "$tmp"
          ${lib.optionalString (cfg.mcp.servers != {}) ''
            # cline_mcp_settings.json: same doctrine (the wizard owns this
            # file; mcpServers is a map, so a plain * merge re-asserts named
            # servers and leaves the user's own untouched).
            tmp="$(mktemp)"
            if [ -s "${mcpTarget}" ] && ! ${pkgs.jq}/bin/jq -e . "${mcpTarget}" >/dev/null 2>&1; then
              cp -f "${mcpTarget}" "${mcpTarget}.cline-nixos-backup"
              cp ${mcpSettingsFile} "$tmp"
            elif [ -s "${mcpTarget}" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "${mcpTarget}" ${mcpSettingsFile} >"$tmp"; then
              :
            else
              cp ${mcpSettingsFile} "$tmp"
            fi
            if cmp -s "$tmp" "${mcpTarget}" 2>/dev/null; then
              rm -f "$tmp"
            else
              install -m 0600 -o ${u} -g ${group} "$tmp" "${mcpTarget}"
            fi
            rm -f "$tmp"
          ''}
        ''
      )
      cfg.users}
  '';

  settingsFile = pkgs.writeText "cline-providers.json" (builtins.toJSON settingsFragment);

  # The declared MCP servers, merged into cline_mcp_settings.json per user
  # (see the mcp.servers option). Only built when there is something to merge.
  mcpSettingsFile = pkgs.writeText "cline-mcp.json" (builtins.toJSON {
    mcpServers = cfg.mcp.servers;
  });
in {
  options.MODULES.services.cline = {
    enable = mkEnableOption ''
      Cline CLI with a declarative provider config: the openai-compatible slot
      in ~/.cline/data/settings/providers.json is pointed at OmniRoute (the
      gateway key is injected as a literal by the activation merge - cline
      sends `file:` indirections unresolved), wrapped to trust the fleet CA
      (bun ships its own roots), and deep-merged per activation so the user's
      own providers survive.
    '';

    package = mkOption {
      type = types.package;
      # npm-deps hash correction (measured 2026-11-09): the cline 3.0.74 node_modules FOD
      # pinned in nixpkgs-unstable f4a03c008967 says dVbQIed8... but the registry now hands
      # out KJsV3HXT... (cache.nixos.org has no build of this rev either - 404 on the output
      # path), i.e. floating deps in bun's resolve drifted since upstream computed it. Drop
      # the override when the pin moves past an upstream hash refresh (then a plain
      # pkgs-unstable.cline evaluates AND substitutes again).
      default =
        pkgs-unstable.cline.overrideAttrs
        (
          final: prev: {
            node_modules = prev.node_modules.overrideAttrs (_: {
              outputHash = "sha256-KJsV3HXT43LuhFikCXyRrKFgpI3NWOckQHT28s9qGZs=";
            });
          }
        );
      defaultText = literalExpression ''
        pkgs-unstable.cline (node_modules outputHash overridden, see comment)
      '';
      description = "cline package the wrapper execs.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.cline provider slot is managed and who can read the mounted gateway key (group users mounts).";
    };

    baseUrl = mkOption {
      type = types.str;
      default = "https://omniroute.hp/v1";
      example = "https://litellm.hp/v1";
      description = "OpenAI-compatible base URL the slot points at (must carry /v1 - Cline appends only /chat/completions).";
    };

    apiKeySecret = mkOption {
      type = types.str;
      default = "omniroute_api_key";
      description = "sops secret whose value the merge unit injects into the managed slot's apiKey.";
    };

    defaultModel = mkOption {
      type = types.str;
      default = "antigravity/claude-sonnet-4-6";
      example = "antigravity/claude-opus-4-6-thinking";
      description = "Model pinned into the slot, in the gateway's own wire spelling (Cline's picker sends exactly this string). Avoid openrouter/* ids: the gateway's openrouter key is capped at $1/day.";
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted provider API-key secret; doctrine in modules/services/pi.nix. The gateway key mount is shared with pi/opencode/omp/kilo, so this must match what those modules declare on the host.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };

    mcp.servers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        blender = {
          command = "mcp-for-blender";
          args = ["--port" "9876"];
          alwaysAllow = [];
          disabled = false;
        };
      };
      description = ''
        Cline's MCP dialect: entries of the `mcpServers` map of
        ~/.cline/data/settings/cline_mcp_settings.json (verified against the
        CLI 2026-11-06: `cline config mcp` reads exactly that file; stdio keys
        command/args/env plus its own alwaysAllow/disabled). The file is
        app-written (the MCP wizard edits it), so the cline-settings merge
        pass deep-merges it per user, exactly like providers.json.
        MODULES.services.blender-mcp feeds the blender entry.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != [];
        message = "MODULES.services.cline.users must name at least one user.";
      }
      {
        assertion = builtins.elem cfg.secretOwner cfg.users || cfg.secretOwner == "root";
        message = ''
          MODULES.services.cline.secretOwner "${cfg.secretOwner}" is neither root nor in
          MODULES.services.cline.users: the key mount ends up readable by nobody who runs cline
          (the merge unit would inject an empty key, and the gateway answers 401).
        '';
      }
      {
        # All harness modules mount the same gateway key secret; sops-nix
        # mounts each name with one owner, so the modules may not disagree.
        assertion =
          !config.MODULES.services.pi.enable || cfg.secretOwner == config.MODULES.services.pi.secretOwner;
        message = "MODULES.services.cline.secretOwner must equal MODULES.services.pi.secretOwner (both mount the gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.opencode.enable
          || cfg.secretOwner == config.MODULES.services.opencode.secretOwner;
        message = "MODULES.services.cline.secretOwner must equal MODULES.services.opencode.secretOwner (both mount the gateway API-key secrets).";
      }
    ];

    # The agent tool layer needs /bin/bash to exist. cline is the harness that
    # drives coding agents, and the tool surface those agents call shells through
    # hard-codes the FHS path, which NixOS does not provide - the failure is an
    # ENOENT at posix_spawn before any command runs, so it looks like "no shell
    # on this machine" rather than a missing path (legion5 2026-11-08).
    # modules/system/bin_bash.nix owns the mechanism; it lives on here, not in a
    # profile, because a host that runs no agent harness has no reason to grow
    # the link.
    MODULES.system.binBash.enable = true;

    sops.secrets.${cfg.apiKeySecret} = {
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
    };

    # The wrapped cline (fleet-CA trust for the bun runtime; see clineWrapper).
    environment.systemPackages = [clineWrapper];

    # The keyless fragment under /etc for inspection; the merge unit injects
    # the real key per user.
    environment.etc."cline/providers.json".source = settingsFile;

    systemd.tmpfiles.rules = lib.flatten (
      map (u: [
        "d ${config.users.users.${u}.home}/.cline 0700 ${u} ${config.users.users.${u}.group} -"
        "d ${config.users.users.${u}.home}/.cline/data 0700 ${u} ${config.users.users.${u}.group} -"
      ])
      cfg.users
    );

    systemd.services.cline-settings = {
      description = "Merge declared Cline providers.json (MODULES.services.cline)";
      after = ["local-fs.target" "sops-nix.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mergeScript;
      };
    };
  };
}
