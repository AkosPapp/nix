# pi (the terminal coding agent, `pi` on PATH) with a fully declarative config -
# the pi twin of modules/services/opencode.nix, and the replacement for what
# MODULES.services.paseo-machine used to hand-write into the home (legion5 2026-10-29:
# the cockpit machine was retired; pi/opencode configs come from NixOS now).
#
# Layout, and why each piece sits where it does:
#   * models.json is a KEYLESS store file exposed as /etc/pi/models.json and symlinked
#     into every configured user's ~/.pi/agent (tmpfiles L+, which also replaces the
#     old plaintext-keyed regular file). pi resolves `"apiKey": "!cat <path>"` itself -
#     resolve-config-value.js execs the command, trims stdout, caches per process - so
#     the key lives only in the sops-nix-mounted file it points at, exactly the
#     {file:...} trick opencode gets from modules/services/opencode.nix. pi has no
#     system config dir (it reads ~/.pi/agent/models.json or nothing), so the symlink
#     IS the declarative mechanism; a `pi update` that tried to rewrite the file would
#     hit the read-only store and fail visibly rather than drift silently.
#   * settings.json cannot be a symlink: pi and `pi install` write it (saved thinking
#     levels, package declarations). A root oneshot deep-merges the declared fragment
#     at activation instead - user keys survive, named keys are re-asserted on every
#     boot/rebuild. The jq merge is the twin of paseo-machine's prepare-script one
#     (deliberate: that one must run as the USER at daemon pre-start and cannot call a
#     root service; if a third copy ever appears, lift it to a shared helper).
#   * defaultProvider/defaultModel MUST be pinned, not left to pi: pi's
#     findInitialModel (dist/core/model-resolver.js) falls through to "first available
#     model with a valid API key" and models.json is rendered from attrsets - the
#     alphabetical provider map puts `futurelab` (the backup!) BEFORE `litellm`. An
#     unpinned pi boots on the backup endpoint (measured on legion5 2026-10-29).
#
# Model ids and display names: pi's footer shows only the model id and the /model
# picker shows "<id> [provider]", so the fully-qualified "provider/id" spelling goes in
# each model's `name` (the one field that can hold it - shown as "Model Name:" in the
# picker and matched by --model patterns and fuzzy search). ids stay the wire spelling,
# which is NOT prefixed for the direct gateways.
#
# What pi's schema forces from the fleet catalogue: MODEL_INPUT_MODALITIES is
# ["text","image"] only, so a catalogue modalities.input of ["text" "image" "video"]
# must have "video" dropped or the WHOLE models.json fails validation (paseo-machine
# dodged this only by never emitting input at all).
#
# nixpkgs has no pi module; this is the fleet's own. The harness facts (window, output,
# thinking levels, costs) come only from MODULES.services.modelCatalog, and the provider
# list mirrors MODULES.services.opencode's defaultProviders (same gateways, same sops
# keys) so pi and opencode always offer the identical set.
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

  cfg = config.MODULES.services.pi;

  catalog = config.MODULES.services.modelCatalog.models;

  # pi's level map keys, fixed by pi (ThinkingLevelMapSchema), weakest first; a level the
  # model does not list is null (pi hides it), and "off" is ALWAYS null - that is pi's way
  # of saying "off sends no reasoning_effort field"; the chat-template kwargs below are
  # what actually stops thinking. Same shape paseo-machine measured against the vLLM fronts.
  piThinkingLevelKeys = ["off" "minimal" "low" "medium" "high" "xhigh" "max"];
  piThinkingLevelMap = levels:
    builtins.listToAttrs (map (l: {
        name = l;
        value =
          if l != "off" && builtins.elem l levels
          then l
          else null;
      })
      piThinkingLevelKeys);

  # The vLLM chat-template kwargs pi puts on the wire for thinking models: compat
  # thinkingFormat=chat-template with $var placeholders resolved through the level map.
  piChatTemplateCompat = {
    thinkingFormat = "chat-template";
    chatTemplateKwargs = {
      thinking = {"$var" = "thinking.enabled";};
      reasoning_effort = {"$var" = "thinking.effort";};
    };
  };

  # pi's cost keys, from the catalogue's opencode-spelled ones (input, output,
  # cache_read, cache_write - shared table, dialect per consumer).
  piCost = c: {
    input = c.input or 0;
    output = c.output or 0;
    cacheRead = c.cache_read or 0;
    cacheWrite = c.cache_write or 0;
  };

  modelSubmodule = {...}: {
    options = {
      contextLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "pi contextWindow; null leaves pi's 128000 default (and its early compaction).";
      };

      outputLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "pi maxTokens; null leaves pi's 16384 default.";
      };

      input = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = ["text" "image"];
        description = "pi `input` modalities - only text and image exist in pi's schema; null omits the field (pi defaults to text).";
      };

      cost = mkOption {
        type = types.nullOr (types.attrsOf types.float);
        default = null;
        example = {
          input = 0.0;
          output = 0.0;
          cache_read = 0.0;
          cache_write = 0.0;
        };
        description = "Catalogue-spelled cost (input/output/cache_read/cache_write, USD per Mtok), rendered into pi's cacheRead/cacheWrite. Null lets pi guess a models.dev price.";
      };

      thinkingLevels = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "reasoning_effort levels the gateway implements; non-empty turns on pi reasoning + chat-template compat. Empty = no thinking offered.";
      };

      thinkingDefault = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Level the default model starts on (the settings.json modelThinkingLevels pin - pi reads it only for the default model).";
      };

      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = literalExpression "\"<provider-key>/<model-key>\"";
        description = "pi's `name`: the picker's detail line and the string --model patterns match against. Defaults to the fully-qualified provider/id spelling.";
      };
    };
  };

  providerSubmodule = {...}: {
    options = {
      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "pi's provider `name` (shown next to the id in listings); defaults to the attribute key.";
      };

      baseUrl = mkOption {
        type = types.str;
        example = "https://litellm.hp/v1";
        description = "OpenAI-compatible endpoint this provider talks to.";
      };

      api = mkOption {
        type = types.str;
        default = "openai-completions";
        description = "pi's API dialect for this provider.";
      };

      apiKeySecret = mkOption {
        type = types.str;
        example = "opencode/litellm_api_key";
        description = ''
          sops key whose mounted file holds this provider's API key. models.json carries
          it as "!cat <mounted path>" - pi execs that as the user running it, so the
          secret must be owned by every cfg.users entry (see the module assertion).
        '';
      };

      discoverModels = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Ask the gateway's /v1/models for its full inventory via the official
          pi-models-discovery extension (models.json `discoverModels`, plus the
          `packages` entry in settings.json that installs the extension). Discovered
          models replace the static entries by id - the thinking dialect survives via
          modelOverrides below.
        '';
      };

      models = mkOption {
        type = types.attrsOf (types.submodule modelSubmodule);
        default = {};
        example = {"futurelab/qwen3.8-flash-next" = {contextLength = 262144;};};
        description = "Models served under this provider, keyed by the id the provider expects on the wire.";
      };
    };
  };

  # A catalogue entry re-spelled for this module's modelSubmodule - the numbers stay in
  # model-catalog.nix; only the vocabulary is pi's (AGENTS.md Rule 2).
  piModelFromCatalog = m: {
    contextLength = m.contextLength;
    outputLength = m.outputLength;
    cost = m.cost;
    # pi's enum is text|image; the catalogue may list more (video) for other harnesses.
    input =
      if m.modalities == null
      then null
      else builtins.filter (x: builtins.elem x ["text" "image"]) m.modalities.input;
    thinkingLevels = m.thinkingLevels;
    thinkingDefault = m.thinkingDefault;
  };

  # The fleet's two gateways in pi dialect - the same endpoints/keys as
  # MODULES.services.opencode.defaultProviders, spelled from the catalogue.
  defaultProviders = {
    litellm = {
      displayName = "LiteLLM (hp)";
      baseUrl = "https://litellm.hp/v1";
      apiKeySecret = "opencode/litellm_api_key";
      # The gateway's inventory grows without a config edit here; the static catalogue
      # entry remains authoritative for THIS model through modelOverrides.
      discoverModels = true;
      models =
        lib.mapAttrs' (
          _: m: lib.nameValuePair m.litellmName (piModelFromCatalog m)
        )
        catalog;
    };
    futurelab = {
      displayName = "FutureLab (Aqueduct)";
      baseUrl = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key";
      # One-model endpoint; nothing to discover.
      models = lib.mapAttrs' (
        _: m: lib.nameValuePair m.directName (piModelFromCatalog m)
      ) (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
  };

  # One configured model as pi wants it. `name` carries the fully-qualified
  # "<provider>/<id>" spelling because pi's footer/picker render only the raw id, and
  # the point of the two-gateway catalogue is that "litellm/futurelab/..." and
  # "futurelab/..." are distinguishable strings.
  piModel = pname: mname: m:
    {
      id = mname;
      name =
        if m.displayName != null
        then m.displayName
        else "${pname}/${mname}";
    }
    // lib.optionalAttrs (m.contextLength != null) {contextWindow = m.contextLength;}
    // lib.optionalAttrs (m.outputLength != null) {maxTokens = m.outputLength;}
    // lib.optionalAttrs (m.input != null && m.input != []) {inherit (m) input;}
    // lib.optionalAttrs (m.cost != null) {cost = piCost m.cost;}
    // lib.optionalAttrs (m.thinkingLevels != []) {
      reasoning = true;
      thinkingLevelMap = piThinkingLevelMap m.thinkingLevels;
      compat = piChatTemplateCompat;
    };

  piProvider = pname: p:
    {
      name =
        if p.displayName != null
        then p.displayName
        else pname;
      baseUrl = p.baseUrl;
      api = p.api;
      apiKey = "!cat ${config.sops.secrets.${p.apiKeySecret}.path}";
      models = lib.mapAttrsToList (piModel pname) p.models;
    }
    // lib.optionalAttrs p.discoverModels {
      discoverModels = true;
      # Discovery replaces the static entry by id - including its thinking dialect, so
      # re-assert it (pi lifts compat reasoning/thinkingLevelMap to the model top level
      # and passes the rest through), and keep the fully-qualified display name.
      modelOverrides = lib.mapAttrs' (
        mname: m:
          lib.nameValuePair mname {
            name = "${pname}/${mname}";
            compat =
              {
                reasoning = true;
                thinkingLevelMap = piThinkingLevelMap m.thinkingLevels;
              }
              // piChatTemplateCompat;
          }
      ) (lib.filterAttrs (_: m: m.thinkingLevels != []) p.models);
    };

  # Resolve "provider/id" for settings.json. The derived default prefers the litellm
  # provider deliberately: the raw attrNames-first pick would be `futurelab`, i.e. the
  # backup endpoint (alphabetical order in the rendered providers map), and an unpinned
  # or mis-pinned pi silently boots there.
  defaultRef =
    if cfg.defaultModel != null
    then cfg.defaultModel
    else if cfg.providers ? litellm && cfg.providers.litellm.models != {}
    then "litellm/${builtins.head (builtins.attrNames cfg.providers.litellm.models)}"
    else "${builtins.head (builtins.attrNames cfg.providers)}/${builtins.head (
      builtins.attrNames cfg.providers.${builtins.head (builtins.attrNames cfg.providers)}.models
    )}";

  defaultParts = lib.splitString "/" defaultRef;
  defaultProviderName = builtins.head defaultParts;
  defaultModelId = lib.concatStringsSep "/" (builtins.tail defaultParts);

  defaultModelEntry = cfg.providers.${defaultProviderName}.models.${defaultModelId} or null;

  # The settings.json fragment: deep-merged at activation; user-written keys survive.
  settingsFragment = pkgs.writeText "pi-settings.json" (builtins.toJSON (
    {
      defaultProvider = defaultProviderName;
      defaultModel = defaultModelId;
    }
    // lib.optionalAttrs (
      defaultModelEntry != null && defaultModelEntry.thinkingDefault != null
    ) {
      modelThinkingLevels = {"${defaultRef}" = defaultModelEntry.thinkingDefault;};
    }
    // lib.optionalAttrs (lib.any (p: p.discoverModels) (lib.attrValues cfg.providers)) {
      packages = [{source = "npm:pi-models-discovery";}];
    }
  ));

  # settings.json belongs to pi (saved levels, `pi install` packages); models.json does
  # not (the /etc symlink owns it). One merge pass per user, as root, at activation.
  # The jq expression is paseo-machine's (prepare script) verbatim, including the
  # list-append carve-out for packages: jq's * replaces arrays wholesale, which would eat
  # packages the user installed with `pi install`.
  mergeScript = pkgs.writeShellScript "pi-settings-merge" ''
    set -eu
    ${lib.concatMapStringsSep "\n" (
        u: let
          home = config.users.users.${u}.home;
          group = config.users.users.${u}.group;
          dir = "${home}/.pi/agent";
          target = "${dir}/settings.json";
        in ''
          # ${u}
          mkdir -p "${dir}"
          chown ${u}:${group} "${dir}"
          chmod 0700 "${dir}"
          tmp="$(mktemp)"
          if [ -s "${target}" ] && ! ${pkgs.jq}/bin/jq -e . "${target}" >/dev/null 2>&1; then
            # Unparseable is not ours to interpret - keep it, start from the fragment.
            cp -f "${target}" "${target}.pi-nixos-backup"
            cp ${settingsFragment} "$tmp"
          elif [ -s "${target}" ] && ${pkgs.jq}/bin/jq -s '((.[0] * .[1]) + (if ((.[0].packages // []) | length) == 0 and ((.[1].packages // []) | length) == 0 then {} else {packages: ((.[0].packages // []) + (.[1].packages // []) | unique_by(if type == "object" then .source else . end))} end))' "${target}" ${settingsFragment} >"$tmp"; then
            :
          else
            cp ${settingsFragment} "$tmp"
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
in {
  options.MODULES.services.pi = {
    enable = mkEnableOption "pi (the terminal coding agent) with declarative models.json/settings.json in the configured users' homes";

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.pi/agent this manages. models.json lands as a symlink to /etc/pi/models.json; settings.json is deep-merged, never replaced wholesale.";
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerSubmodule);
      default = defaultProviders;
      defaultText = literalExpression "the fleet's shared gateway catalogue (litellm + futurelab), rendered from MODULES.services.modelCatalog";
      description = ''
        pi providers, keyed by the provider id pi uses (also the "<provider>" half of
        defaultModel and of every model's fully-qualified name). Option defaults mean a
        host that wants the standard fleet setup just sets `enable` + `users`; `mkForce`
        replaces the whole catalogue. Like MODULES.services.opencode's default, enabling
        this pulls the gateways' sops secrets onto the host.
      '';
    };

    defaultModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "litellm/futurelab/qwen3.8-flash-next";
      defaultText = literalExpression "the litellm provider's first catalogue model (never the alphabetical first, which would be the futurelab backup)";
      description = ''
        "provider/id" pi starts with, written as settings.json defaultProvider +
        defaultModel (the split is at the FIRST slash, so a LiteLLM model id that itself
        contains slashes round-trips correctly). Pinned because pi otherwise boots
        whatever provider key sorts first - with the backup catalogue that is futurelab.
      '';
    };

    secretOwner = mkOption {
      type = types.str;
      default = "akos";
      example = "root";
      description = ''
        Owner of the mounted provider API-key secrets - same option (and same default) as
        MODULES.services.opencode.secretOwner, because both modules mount the same two
        gateway keys; they must agree (asserted). pi runs `!cat <path>` as the user
        running pi, so every cfg.users entry must be able to read the mount - with the
        0400 default that means the owner IS the pi user.
      '';
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.users != [];
          message = "MODULES.services.pi.enable needs MODULES.services.pi.users - pi reads only ~/.pi/agent, so at least one home must be named.";
        }
        {
          assertion = builtins.all (u: config.users.users ? ${u}) cfg.users;
          message = "MODULES.services.pi.users names a user this system does not define.";
        }
        {
          assertion = builtins.elem cfg.secretOwner cfg.users;
          message = ''
            MODULES.services.pi.secretOwner "${cfg.secretOwner}" is not in MODULES.services.pi.users:
            pi resolves its API keys by cat-ing the mounted secret file AS THE PI USER,
            so a secret owned by someone else is unreadable (0400) at first request.
          '';
        }
        {
          assertion =
            defaultModelEntry != null && builtins.length defaultParts >= 2;
          message = ''
            MODULES.services.pi: defaultModel "${defaultRef}" must be "provider/id" naming
            a configured provider and model (the id half may contain slashes).
          '';
        }
        {
          assertion =
            builtins.all (
              m:
                m.input
                == null
                || builtins.all (x: builtins.elem x ["text" "image"]) m.input
            ) (
              lib.flatten (map (p: lib.attrValues p.models) (lib.attrValues cfg.providers))
            );
          message = ''
            MODULES.services.pi: pi's models.json schema accepts only "text" and "image"
            as input modalities - anything else fails the WHOLE file.
          '';
        }
      ]
      ++ lib.optionals (config.MODULES.services.opencode.enable or false) [
        {
          # Both modules default the same sops secrets; sops-nix mounts each name with one
          # owner, so the two modules may not disagree about who reads them.
          assertion =
            cfg.secretOwner == config.MODULES.services.opencode.secretOwner;
          message = "MODULES.services.pi.secretOwner must equal MODULES.services.opencode.secretOwner (both mount the gateway API-key secrets).";
        }
        {
          assertion =
            cfg.secretGroup == config.MODULES.services.opencode.secretGroup;
          message = "MODULES.services.pi.secretGroup must equal MODULES.services.opencode.secretGroup (both mount the gateway API-key secrets).";
        }
      ];

    sops.secrets =
      lib.genAttrs (
        lib.unique (map (p: p.apiKeySecret) (lib.attrValues cfg.providers))
      ) (_: {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      });

    environment.systemPackages = [pkgs-unstable.pi-coding-agent];

    # The keyless catalogue, world-readable: it names secret PATHS, never secrets.
    environment.etc."pi/models.json".text = builtins.toJSON {
      "$schema" = "https://pi.dev/schemas/models.schema.json";
      providers = lib.mapAttrs piProvider cfg.providers;
    };

    # L+ replaces whatever is there (including the old daemon-written regular file with
    # inline keys) - self-healing on every boot and every activation, since NixOS re-runs
    # tmpfiles during switch. The d rules keep the agent dir the user's own, which pi
    # needs for sessions/, npm/, extensions/ and settings.json.
    systemd.tmpfiles.rules = lib.flatten (
      map (u: [
        "d ${config.users.users.${u}.home}/.pi 0700 ${u} ${config.users.users.${u}.group} -"
        "d ${config.users.users.${u}.home}/.pi/agent 0700 ${u} ${config.users.users.${u}.group} -"
        "L+ ${config.users.users.${u}.home}/.pi/agent/models.json - - - - /etc/pi/models.json"
      ])
      cfg.users
    );

    systemd.services.pi-settings = {
      description = "Merge declared pi settings.json (MODULES.services.pi)";
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mergeScript;
      };
    };
  };
}
