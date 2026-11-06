# Kilo Code CLI (`kilo`) with declarative gateway config - the fleet's twin of
# modules/services/opencode.nix for the OpenCode fork Kilo ships (docs: "The
# Kilo CLI is a fork of OpenCode and supports the same configuration options",
# kilo.ai/docs/code-with-ai/platforms/cli). nixpkgs `kilo` is broken
# (NixOS/nixpkgs#542516), so the package comes from packages/kilo-cli.nix.
#
# Differences from opencode that matter here (each verified against the v7.8.18
# binary or the CLI docs on 2026-11-05):
#   * Config dir is ~/.config/kilo and the file is kilo.json(c) - the legacy
#     opencode.json fallback is read, but ~/.config/opencode is NOT (docs warn
#     explicitly), so this module renders its own file instead of sharing
#     opencode's. Same keyless + {file:<sops path>} apiKey doctrine as
#     modules/services/opencode.nix, which the fork's schema accepts verbatim.
#   * {env:VAR}/{file:VAR} references resolve ONLY in trusted config (global
#     ~/.config/kilo, KILO_CONFIG, or org-managed) - never in project config -
#     so the sops-mount apiKey form below must stay in the GLOBAL layer; a
#     project ./kilo.json cannot use it to exfiltrate. The per-user file the
#     merge unit writes IS the global layer.
#   * The opencode discovery plugin has no kilo twin: kilo ships its own
#     provider registry and the openai-compatible provider honours baseUrl +
#     model overrides from config, which is enough for the two gateways here.
#     Gateway models outside kilo's registry need static rows (catalogue
#     facts are filled in by directName; hosts add what they want).
#   * Telemetry is ON by default in kilo (experimental.openTelemetry); the
#     fleet's privacy default turns it off - hosts can re-enable.
#   * kilo.jsonc is an app-WRITTEN file (kilo's own config writes land there),
#     so it cannot be a store symlink - a root oneshot deep-merges the declared
#     fragment at activation, the pi.nix settings-merge doctrine (user keys
#     survive, our providers are re-asserted).
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

  cfg = config.MODULES.services.kilo;

  catalog = config.MODULES.services.modelCatalog.models;

  # Catalogue entry for a wire id (the directName - the "futurelab/..." key
  # only ever existed in LiteLLM's spelling; see model-catalog.nix). {} when
  # the id is not in the shared table, so renders fall back to the explicit
  # per-model options below.
  catalogFor = n: let
    hits = builtins.attrValues (lib.filterAttrs (_: m: m.directName == n) catalog);
  in
    if hits == []
    then {}
    else builtins.head hits;

  # The gateways, shared with modules/services/pi.nix / omp.nix /
  # opencode.nix (same gateways, same sops keys, so every harness offers the
  # identical set). futurelab is the static Aqueduct endpoint; omniroute is
  # the subscription-bypass gateway (its wire model ids carry the connection
  # prefix, e.g. "openrouter/anthropic/claude-sonnet-4.5", and the model is
  # spelled "<provider-id>/<that-id>" in every picker and --model flag).
  defaultProviders = {
    futurelab = {
      npm = "@ai-sdk/openai-compatible";
      baseUrl = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key";
      # One-model endpoint; nothing to discover. Keyed by directName, facts
      # filled from the shared table at render time (AGENTS.md Rule 2).
      models = lib.mapAttrs' (
        _: m: lib.nameValuePair m.directName {}
      ) (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
    omniroute = {
      npm = "@ai-sdk/openai-compatible";
      baseUrl = "https://omniroute.hp/v1";
      apiKeySecret = "omniroute_api_key";
      # No static rows: whatever kilo's registry knows is what the picker
      # offers; hosts pin specific gateway models as needed.
      models = {};
    };
  };

  # Render one provider into kilo's OpenCode-schema dialect: apiKey as a
  # {file:...} reference into its sops mount (never a literal key in the
  # store), model facts defaulted from the fleet catalogue by directName. The
  # endpoint goes into options.baseURL (camelCase, nested) because that is
  # where the OpenCode schema reads it - a provider-level `baseUrl` is
  # ignored and kilo then errors "Invalid URL" on the first turn (measured
  # legion5 2026-11-05). Model `name` rows carry the fully-qualified
  # "<provider>/<id>" spelling so the picker distinguishes gateways (same
  # doctrine as opencode.nix/pi.nix).
  providerPackage = _pname: p: {
    inherit (p) npm;
    name = _pname;
    options =
      {baseURL = p.baseUrl;}
      // p.options
      // lib.optionalAttrs (p.apiKeySecret != null) {
        apiKey = "{file:${config.sops.secrets.${p.apiKeySecret}.path}}";
      };
    models =
      lib.mapAttrs (
        name: m: let
          c = catalogFor name;
          # Catalogue fields are nullOr options (present-but-null on a hit,
          # missing on a `{}` miss), so every one is read through `or null`
          # and emitted only when non-null - `x or default` would hand back
          # the null on a hit.
          ctx = c.contextLength or null;
          out = c.outputLength or null;
          mods = c.modalities or null;
          cost = c.cost or null;
        in
          {
            name = "${_pname}/${name}";
          }
          // lib.optionalAttrs (m.limit != {} || ctx != null || out != null) {
            limit =
              (lib.optionalAttrs (ctx != null) {context = ctx;})
              // (lib.optionalAttrs (out != null) {output = out;})
              // m.limit;
          }
          // lib.optionalAttrs (m.modalities != {} || (mods != null && mods != {})) {
            modalities =
              (
                if mods == null
                then {}
                else mods
              )
              // m.modalities;
          }
          // lib.optionalAttrs (m.cost != {} || (cost != null && cost != {})) {
            cost =
              (
                if cost == null
                then {}
                else cost
              )
              // m.cost;
          }
          // lib.optionalAttrs (m.options != {}) {
            inherit (m) options;
          }
      )
      p.models;
  };

  settingsFragment = {
    model = cfg.defaultModel;
    small_model = cfg.smallModel;
    provider = lib.mapAttrs providerPackage cfg.providers;
    experimental.openTelemetry = cfg.telemetry;
  };

  settingsFile = pkgs.writeText "kilo-settings.json" (builtins.toJSON settingsFragment);

  # Deep-merge (jq *), pi.nix doctrine: user keys survive, our providers are
  # re-asserted on top; unparseable files are backed up, never destroyed.
  mergeScript = pkgs.writeShellScript "kilo-settings-merge" ''
    set -eu
    ${lib.concatMapStringsSep "\n" (
        u: let
          home = config.users.users.${u}.home;
          group = config.users.users.${u}.group;
          dir = "${home}/.config/kilo";
          target = "${dir}/kilo.jsonc";
        in ''
          # ${u}
          mkdir -p "${dir}"
          chown ${u}:${group} "${dir}"
          chmod 0700 "${dir}"
          tmp="$(mktemp)"
          if [ -s "${target}" ] && ! ${pkgs.jq}/bin/jq -e . "${target}" >/dev/null 2>&1; then
            # Unparseable is not ours to interpret - keep it, start from the fragment.
            cp -f "${target}" "${target}.kilo-nixos-backup"
            cp ${settingsFile} "$tmp"
          elif [ -s "${target}" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "${target}" ${settingsFile} >"$tmp"; then
            :
          else
            cp ${settingsFile} "$tmp"
          fi
          if cmp -s "$tmp" "${target}" 2>/dev/null; then
            rm -f "$tmp"
          else
            install -m 0600 -o ${u} -g ${group} "$tmp" "${target}"
          fi
          rm -f "$tmp"
        ''
      )
      cfg.users}
  '';

  # The deterministic-default doctrine (pi.nix): only STATIC catalogue rows
  # make the default model predictable, so it pins the futurelab provider's
  # first model (omniroute is registry/discovery-driven and its listing moves).
  futurelabFirstModel =
    if cfg.providers ? futurelab && cfg.providers.futurelab.models != {}
    then builtins.head (builtins.attrNames cfg.providers.futurelab.models)
    else null;
in {
  options.MODULES.services.kilo = {
    enable = mkEnableOption ''
      Kilo Code CLI (the OpenCode fork) with a declarative global config:
      the gateway providers render keyless into ~/.config/kilo/kilo.jsonc
      (API keys as {file:<sops mount>} references, trusted-global-config-only
      per upstream), and a per-activation jq merge keeps user keys while
      re-asserting the declared ones. The nixpkgs kilo attr is broken, so the
      package defaults to packages/kilo-cli.nix (vendor linux-x64 binary).
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/kilo-cli.nix {};
      defaultText = literalExpression "pkgs.callPackage ../../packages/kilo-cli.nix {}";
      description = "kilo package on PATH (the store is not writable, so kilo's own updater cannot work - upgrades happen by bumping this option).";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.config/kilo/kilo.jsonc is managed and who get the sops-mounted gateway keys readable (group `users` mounts).";
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule (
        {...}: {
          options = {
            npm = mkOption {
              type = types.str;
              description = "AI-SDK provider package (kilo's OpenCode schema `npm` field).";
            };
            baseUrl = mkOption {
              type = types.str;
              description = "Provider base URL (must carry the /v1 suffix for the openai-compatible SDK).";
            };
            apiKeySecret = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "sops secret name whose mount renders as the provider apiKey's {file:...} reference; null leaves the key to `kilo auth`.";
            };
            options = mkOption {
              type = types.attrs;
              default = {};
              description = "Provider-level options passthrough (OpenCode semantics).";
            };
            models = mkOption {
              type = types.attrsOf (types.submodule (
                _: {
                  options = {
                    limit = mkOption {
                      type = types.attrsOf types.ints.unsigned;
                      default = {};
                      description = "limit override; defaults from MODULES.services.modelCatalog by directName.";
                    };
                    modalities = mkOption {
                      type = types.attrsOf (types.listOf types.str);
                      default = {};
                      description = "modalities override; defaults from MODULES.services.modelCatalog by directName.";
                    };
                    cost = mkOption {
                      type = types.attrsOf (types.attrsOf types.number);
                      default = {};
                      description = "cost override (opencode-spelled keys); defaults from MODULES.services.modelCatalog by directName.";
                    };
                    options = mkOption {
                      type = types.attrs;
                      default = {};
                      description = "Per-model provider options (passthrough, OpenCode semantics).";
                    };
                  };
                }
              ));
              default = {};
              description = "Static model rows (facts default from MODULES.services.modelCatalog); {} offers only what kilo's own registry knows.";
            };
          };
        }
      ));
      default = defaultProviders;
      defaultText = literalExpression "the two gateway providers (futurelab direct + omniroute), rendered from MODULES.services.modelCatalog";
      description = "Provider catalogue rendered into kilo.jsonc; override or extend to taste.";
    };

    defaultModel = mkOption {
      type = types.str;
      default =
        if futurelabFirstModel != null
        then "futurelab/${futurelabFirstModel}"
        else throw "MODULES.services.kilo.defaultModel: no futurelab provider with static models to derive it from - name the model explicitly";
      defaultText = literalExpression "the fleet futurelab model, futurelab-qualified";
      description = "kilo `model` pin (provider-id/model-id spelling, fully-qualified so gateway models stay distinguishable).";
    };

    smallModel = mkOption {
      type = types.str;
      default = cfg.defaultModel;
      defaultText = literalExpression "MODULES.services.kilo.defaultModel";
      description = "kilo `small_model` pin (title/summarisation duty).";
    };

    telemetry = mkOption {
      type = types.bool;
      default = false;
      description = "kilo's experimental.openTelemetry trace export. Off by default (fleet privacy posture); upstream ships it ON.";
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted provider API-key secrets; doctrine in modules/services/pi.nix. Must be one of users.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != [];
        message = "MODULES.services.kilo.users must name at least one user.";
      }
      {
        assertion = builtins.elem cfg.secretOwner cfg.users;
        message = ''
          MODULES.services.kilo.secretOwner "${cfg.secretOwner}" is not in
          MODULES.services.kilo.users - the gateway key mounts would be readable by
          nobody who runs kilo.
        '';
      }
      {
        # The sops mounts are shared with pi/opencode/omp; sops-nix mounts each
        # name with one owner, so all harness modules must agree on it.
        assertion =
          !config.MODULES.services.pi.enable || cfg.secretOwner == config.MODULES.services.pi.secretOwner;
        message = "MODULES.services.kilo.secretOwner must equal MODULES.services.pi.secretOwner (both mount the gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.opencode.enable
          || cfg.secretOwner == config.MODULES.services.opencode.secretOwner;
        message = "MODULES.services.kilo.secretOwner must equal MODULES.services.opencode.secretOwner (both mount the gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.omp.enable || cfg.secretOwner == config.MODULES.services.omp.secretOwner;
        message = "MODULES.services.kilo.secretOwner must equal MODULES.services.omp.secretOwner (both mount the gateway API-key secrets).";
      }
    ];

    sops.secrets =
      lib.genAttrs (
        lib.unique (
          map (p: p.apiKeySecret) (
            lib.attrValues (lib.filterAttrs (_: p: p.apiKeySecret != null) cfg.providers)
          )
        )
      ) (_: {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      });

    environment.systemPackages = [cfg.package];

    # The keyless rendered fragment, world-readable under /etc: it names
    # secret PATHS, never secrets (pi/opencode doctrine). The merge unit
    # installs it into each user's ~/.config/kilo.
    environment.etc."kilo/settings.json".source = settingsFile;

    systemd.tmpfiles.rules = lib.flatten (
      map (u: [
        "d ${config.users.users.${u}.home}/.config 0700 ${u} ${config.users.users.${u}.group} -"
        "d ${config.users.users.${u}.home}/.config/kilo 0700 ${u} ${config.users.users.${u}.group} -"
      ])
      cfg.users
    );

    systemd.services.kilo-settings = {
      description = "Merge declared kilo config (MODULES.services.kilo)";
      after = ["local-fs.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mergeScript;
      };
    };
  };
}
