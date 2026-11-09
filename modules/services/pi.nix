# pi (the terminal coding agent, `pi` on PATH) with a fully declarative config -
# the pi twin of modules/services/opencode.nix, and the replacement for what
# MODULES.services.paseo-machine used to hand-write into the home (legion5 2026-10-29:
# the cockpit machine was retired; pi/opencode configs come from NixOS now).
#
# Layout, and why each piece sits where it does:
#   * models.json is a KEYLESS store file exposed as /etc/pi/models.json and symlinked
#     into every configured user's ~/.pi/agent (tmpfiles L+, which also replaces the
#     old plaintext-keyed regular file). Provider keys render as "$PI_<NAME>_API_KEY"
#     and the module's package wrapper (piWrapper below) exports them from the
#     sops-nix-mounted files at exec time - so the key lives only in the mounted file
#     and the pi process's own environment, never in the store. The wrapper exists
#     because pi-models-discovery deliberately refuses to resolve "!command" apiKeys
#     (its docs: only literals and $ENV interpolation are allowed in discovery
#     requests; pi resolves !commands for CHAT only) - the old "!cat <path>" form
#     made pi's own requests work but killed discovery for every provider
#     (legion5 2026-11-05). pi's resolve-config-value.js interpolates $VAR natively,
#     so chat follows the same mechanism; paseo-machine already runs pi on exactly
#     this pattern ($PASEO_MODEL_API_KEY). pi has no system config dir (it reads
#     ~/.pi/agent/models.json or nothing), so the symlink IS the declarative
#     mechanism; a `pi update` that tried to rewrite the file would hit the read-only
#     store and fail visibly rather than drift silently.
#   * settings.json cannot be a symlink: pi and `pi install` write it (saved thinking
#     levels, package declarations). A root oneshot deep-merges the declared fragment
#     at activation instead - user keys survive, named keys are re-asserted on every
#     boot/rebuild. The jq merge is the twin of paseo-machine's prepare-script one
#     (deliberate: that one must run as the USER at daemon pre-start and cannot call a
#     root service; if a third copy ever appears, lift it to a shared helper).
#   * defaultProvider/defaultModel MUST be pinned, not left to pi: pi's
#     findInitialModel (dist/core/model-resolver.js) falls through to "first available
#     model with a valid API key" and models.json is rendered from attrsets - provider
#     order is then an accident of naming (measured on legion5 2026-10-29). The pin is
#     the futurelab endpoint's first catalogue model since 2026-11-05; only a STATIC
#     catalogue entry makes the default deterministic (omniroute is discovery-only).
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
        example = "https://omniroute.hp/v1";
        description = "OpenAI-compatible endpoint this provider talks to.";
      };

      api = mkOption {
        type = types.str;
        default = "openai-completions";
        description = "pi's API dialect for this provider.";
      };

      apiKeySecret = mkOption {
        type = types.str;
        example = "omniroute_api_key";
        description = ''
          sops key whose mounted file holds this provider's API key. models.json
          references it as "$PI_<NAME>_API_KEY" and the module's piWrapper execs
          `cat <mounted path>` into that env var at every pi start - so the secret must
          be readable by every cfg.users entry (see the module assertion), and providers
          added to cfg.providers get their export automatically.
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
          modelOverrides below. The extension resolves provider apiKeys only as
          literals or $ENV_VAR interpolation (it never execs "!command" - pi does that
          for chat requests only), which is why apiKey is rendered as a $PI_*-style
          env reference fed by piWrapper; a provider that re-renders with "!cat" would
          silently lose discovery while chatting still worked (legion5 2026-11-05).
          Id shape: gateways namespace their own ids, so pi lists e.g.
          "codex/gpt-6-astra [omniroute]" and selections read
          "omniroute/codex/gpt-6-astra". The extension has NO exclude/filter option
          (verified against 1.7.0), so unlike the opencode twin - which drops OmniRoute's
          handful of prefix-less duplicate ids via discoverExcludeIds - pi also shows
          those bare spellings; prefer the provider-qualified ones, as the gateway
          routes bare names to its openai connection.
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

  # The fleet's gateways in pi dialect - the same endpoints/keys as
  # MODULES.services.opencode.defaultProviders, spelled from the catalogue. The harness
  # provider for this fleet's LiteLLM gateway was dropped 2026-11-05 (phase 2 of the
  # OmniRoute replacement; litellm.nix stays for service consumers until phase 3):
  # subscriptions go through omniroute below, Aqueduct goes direct, and a consumer that
  # still wants the old gateway adds its own `providers.litellm = {...}`.
  defaultProviders = {
    futurelab = {
      displayName = "FutureLab (Aqueduct)";
      baseUrl = "https://futurelab.robo4you.at/v1";
      # One of the three Aqueduct virtual keys (futurelab_api_key1/2/3), split per harness
      # so direct-to-Aqueduct traffic doesn't stack on one quota: kilo 1, omp 2,
      # opencode 3, pi 1. The gateways carry all three and rotate per request
      # (litellm.nix's replica deployments, omniroute.nix's extraApiKeys).
      apiKeySecret = "futurelab_api_key1";
      # One-model endpoint; nothing to discover.
      models = lib.mapAttrs' (
        _: m: lib.nameValuePair m.directName (piModelFromCatalog m)
      ) (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
    # The subscription bypass: OmniRoute direct (see modules/services/omniroute.nix - hosted
    # subscription logins are its job, and its dashboard-managed codex OAuth connection
    # answers "codex/<model>" here, i.e. pi shows "omniroute/codex/<model>" with the module's
    # display-name spelling). Nothing statically pinned - OmniRoute's provider set moves -
    # the discovery extension lists it, and that extension has NO exclude/filter option
    # (pi-models-discovery 1.7.0), so OmniRoute's free-tier image providers (aihorde/* and
    # friends) show up too.
    omniroute = {
      displayName = "OmniRoute (hp)";
      baseUrl = "https://omniroute.hp/v1";
      apiKeySecret = "omniroute_api_key";
      discoverModels = true;
      models = {};
    };
  };

  # One configured model as pi wants it. `name` carries the fully-qualified
  # "<provider>/<id>" spelling because pi's footer/picker render only the raw id, and
  # the point of the multi-gateway catalogue is that "omniroute/openrouter/anthropic/..."
  # and "futurelab/..." are distinguishable strings.
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

  # The env var name piWrapper exports each provider's key under, and which the
  # models.json apiKey fields reference (see the header's wrapper rationale).
  piEnvName = pname: "PI_" + lib.toUpper (lib.replaceStrings ["-"] ["_"] pname) + "_API_KEY";

  piProvider = pname: p:
    {
      name =
        if p.displayName != null
        then p.displayName
        else pname;
      baseUrl = p.baseUrl;
      api = p.api;
      # Resolved by pi (resolve-config-value.js) and by pi-models-discovery alike; the
      # values come from the mounted sops files via piWrapper, NOT "!cat <path>" - the
      # discovery extension refuses !command apiKeys outright (see header). Built by
      # concatenation on purpose: in a plain Nix string "$${expr}" is the ESCAPE for a
      # literal ${expr}, so the interpolation-shaped spelling rendered dead text here.
      apiKey = "$" + piEnvName pname;
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

  # The `pi` on PATH: exports every provider's API key from its sops-nix-mounted file
  # (files read at exec, so no secret ever lands in the store or in world-readable env),
  # defaults the pi-extensions-i18n locale to English - that sidecar (a hard
  # dependency of pi-models-discovery, loaded because pi loads every extension-shaped
  # package in its npm store) prints Chinese startup/diagnostic messages unless
  # PI_EXTENSIONS_LOCALE or its agent-dir config overrides its zh-CN default
  # (legion5 2026-11-05). The :- form keeps a user-set value authoritative. It also
  # puts nodejs's bin dir on PATH: pi self-installs settings.json packages by
  # spawning a bare `npm install --prefix ~/.pi/agent/npm` on first run, and a NixOS
  # box without the nodejs package anywhere has no `npm` to find - pi died with
  # `spawn npm ENOENT` (legion5 2026-11-05). Same nodejs derivation pi-coding-agent
  # itself depends on, so the npm matches pi's node.
  piWrapper = pkgs.writeShellScriptBin "pi" (
    ''
      export PI_EXTENSIONS_LOCALE="''${PI_EXTENSIONS_LOCALE:-en}"
      export PATH="${pkgs-unstable.nodejs}/bin:''${PATH}"
    ''
    + lib.concatMapStringsSep "\n" (
      pname: let
        path = config.sops.secrets.${cfg.providers.${pname}.apiKeySecret}.path;
      in ''
        if [ -r ${path} ]; then
          export ${piEnvName pname}="$(cat ${path})"
        fi
      ''
    ) (lib.attrNames cfg.providers)
    + ''
      exec ${pkgs-unstable.pi-coding-agent}/bin/pi "$@"
    ''
  );

  # Resolve "provider/id" for settings.json. The derived default pins the futurelab
  # provider deliberately: it is the only one with STATIC entries, so its first catalogue
  # model is a deterministic boot choice; pi's findInitialModel would otherwise boot on
  # whatever attrsets order renders first (measured on legion5 2026-10-29, when the pin
  # still named the litellm gateway - that harness provider was dropped 2026-11-05).
  defaultRef =
    if cfg.defaultModel != null
    then cfg.defaultModel
    else if cfg.providers ? futurelab && cfg.providers.futurelab.models != {}
    then "futurelab/${builtins.head (builtins.attrNames cfg.providers.futurelab.models)}"
    else "${builtins.head (builtins.attrNames cfg.providers)}/${builtins.head (
      builtins.attrNames cfg.providers.${builtins.head (builtins.attrNames cfg.providers)}.models
    )}";

  defaultParts = lib.splitString "/" defaultRef;
  defaultProviderName = builtins.head defaultParts;
  defaultModelId = lib.concatStringsSep "/" (builtins.tail defaultParts);

  defaultModelEntry = cfg.providers.${defaultProviderName}.models.${defaultModelId} or null;

  # settings.json `packages`: pi npm-installs these into each managed ~/.pi/agent on
  # first run. pi-models-discovery joins automatically whenever any provider uses
  # discoverModels (it IS the discovery implementer); cfg.packages adds further
  # `pi install`-syntax sources.
  packageSources =
    lib.optionals (lib.any (p: p.discoverModels) (lib.attrValues cfg.providers)) ["npm:pi-models-discovery"]
    ++ cfg.packages;

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
    // lib.optionalAttrs (packageSources != []) {
      packages = map (source: {inherit source;}) packageSources;
    }
  ));

  # pi's mcp.json is app-written too (`pi mcp add` lands there), so the same
  # merge doctrine applies: user servers survive, declared ones are re-asserted
  # on top. {} renders as an empty mcpServers map, which merges as a no-op.
  mcpFragment = pkgs.writeText "pi-mcp.json" (builtins.toJSON {
    mcpServers = cfg.mcp.servers;
  });

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
          mcpTarget = "${dir}/mcp.json";
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
          ${lib.optionalString (cfg.mcp.servers != {}) ''
            # mcp.json: same doctrine, no list carve-out (mcpServers is a map).
            tmp="$(mktemp)"
            if [ -s "${mcpTarget}" ] && ! ${pkgs.jq}/bin/jq -e . "${mcpTarget}" >/dev/null 2>&1; then
              cp -f "${mcpTarget}" "${mcpTarget}.pi-nixos-backup"
              cp ${mcpFragment} "$tmp"
            elif [ -s "${mcpTarget}" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "${mcpTarget}" ${mcpFragment} >"$tmp"; then
              :
            else
              cp ${mcpFragment} "$tmp"
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
in {
  options.MODULES.services.pi = {
    enable = mkEnableOption "pi (the terminal coding agent) with declarative models.json/settings.json in the configured users' homes";

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.pi/agent this manages. models.json lands as a symlink to /etc/pi/models.json; settings.json is deep-merged, never replaced wholesale.";
    };

    packages = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["npm:pi-subagents" "git:github.com/user/pi-extension"];
      description = ''
        Extra pi packages loaded into every managed ~/.pi/agent, in `pi install`
        source syntax (`npm:<pkg>`, `git:<owner>/<repo>`, ...). They join the
        settings.json `packages` list alongside pi-models-discovery, which the module
        adds on its own whenever a provider sets discoverModels. pi installs entries
        from this list on first run; the activation merge appends to (never replaces)
        packages the user installed interactively.
      '';
    };

    mcp.servers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        blender = {
          command = "mcp-for-blender";
          args = ["--port" "9876"];
        };
      };
      description = ''
        pi's mcp.json dialect (command/args/env stdio entries, keyed by server
        name): deep-merged into every managed ~/.pi/agent/mcp.json at
        activation (jq *), so servers the user added with `pi mcp add` survive
        and named entries are re-asserted. MODULES.services.blender-mcp feeds
        the blender entry.
      '';
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerSubmodule);
      default = defaultProviders;
      defaultText = literalExpression "the fleet's shared gateway catalogue (futurelab + omniroute), rendered from MODULES.services.modelCatalog";
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
      example = "omniroute/codex/gpt-6-astra";
      defaultText = literalExpression "the futurelab provider's first catalogue model (the only static provider; discovery-only omniroute cannot give a deterministic default)";
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

    # The wrapped pi (env exports + locale default; see piWrapper).
    environment.systemPackages = [piWrapper];

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
