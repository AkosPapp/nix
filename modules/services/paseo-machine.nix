{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.paseo-machine;

  paseoCli = pkgs.callPackage ../../packages/paseo/cli.nix {};

  # The hub this machine joins by default (modules/services/paseo.nix on hp): the relay is the
  # public dial-out endpoint (Funnel's 10000, bare host:port, protocol-fixed /ws) and hubUrl is
  # the cockpit's funnel origin, whose token-gated /paseo-api/register endpoint takes the
  # pairing link. Override per host to point a fleet at another hub.
  hubFqdn = "hp.tail546fb.ts.net";

  # The model's own numbers, spelled per harness. Both harnesses describe the single model this
  # machine dials out to, in their own vocabulary:
  #
  #   limit    pi: contextWindow / maxTokens      opencode: limit.context / limit.output
  #   thinking pi: reasoning + thinkingLevelMap   opencode: options + variants
  #            + compat.chatTemplateKwargs
  #
  # Nothing here has a default: a host that names a model also states what it can do, and unset
  # options write no fields at all, so these values never leak onto a model they were not meant
  # for. Without them both harnesses guess - pi assumes 128000/16384 (and then compacts at
  # contextWindow - 16384, ~111K instead of the real window) and reports the model as unable to
  # think, so /thinking has nothing to offer.
  modelLimitContext = cfg.modelContextLength;
  modelLimitOutput = cfg.modelOutputLength;
  hasModelLimits = modelLimitContext != null || modelLimitOutput != null;

  # Thinking levels, weakest first. Rendered into pi's level map (unsupported levels null, so pi
  # hides them - and "off": null, which is pi's way of saying "off sends no effort field at all")
  # and into opencode's variant set; cfg.modelThinkingDefault is the one a session starts on.
  piThinkingLevelKeys = ["off" "minimal" "low" "medium" "high" "xhigh" "max"];
  piThinkingLevelMap = builtins.listToAttrs (map (l: {
      name = l;
      value =
        if l != "off" && builtins.elem l cfg.modelThinkingLevels
        then l
        else null;
    })
    piThinkingLevelKeys);

  # The gateway takes thinking as vLLM-style chat_template_kwargs (same shape users/akos.nix
  # hand-writes for the interactive opencode): pi needs compat.thinkingFormat = "chat-template"
  # to put them on the wire at all, opencode just sends them as model options.
  thinkingKwargs = e: {
    chat_template_kwargs = {
      thinking = true;
      reasoning_effort = e;
    };
  };
  opencodeVariants =
    {
      # Variants merge over the model's base options, so "off" has to switch the base thinking flag
      # off too.
      off = {
        enable_thinking = false;
        chat_template_kwargs.thinking = false;
      };
    }
    // builtins.listToAttrs (map (e: {
        name = e;
        value = thinkingKwargs e;
      })
      cfg.modelThinkingLevels);
  hasModelThinking = cfg.modelThinkingLevels != [];
  # A startup level only makes sense among the levels the model lists: defaulting a low/medium-only
  # model to xhigh would make every session open with a request the gateway rejects.
  thinkingDefaultListed =
    !hasModelThinking || lib.elem cfg.modelThinkingDefault cfg.modelThinkingLevels;

  # pi's startup thinking level lives in settings.json (models.json has no such field), keyed by
  # exact "provider/modelId" so it is a default for THIS model and changes nothing about any other
  # model pi might drive. pi writes this same file when the user saves a level with Ctrl+S, which
  # is why the prepare script merges this fragment instead of replacing the file.
  #
  # packages: when model discovery is on, this is what pulls the official pi-models-discovery
  # extension - pi reads package declarations from settings.json and installs them (from npm)
  # itself at the first startup or /reload.
  piSettings = pkgs.writeText "paseo-machine-pi-settings.json" (builtins.toJSON {
    packages =
      lib.optionals cfg.modelDiscoverModels [{source = "npm:pi-models-discovery";}];
    modelThinkingLevels = {"${cfg.modelProvider}/${cfg.modelId}" = cfg.modelThinkingDefault;};
  });

  # Where model discovery is enabled, the discovered litellm inventory replaces the static
  # entries by id - including cfg.modelId, whose advertised metadata carries no thinking info.
  # The override re-asserts exactly what the hand-curated entry says for this model, so the
  # wildcard-discovered "futurelab/qwen3.8-flash-next" still thinks the way LiteLLM's gateway
  # wants: vLLM-style chat-template kwargs, with the level map in compat (pi lifts compat
  # reasoning/thinkingLevelMap to the model's top level, the other keys through as-is).
  qwenDiscoveryOverride = lib.optionalAttrs (hasModelThinking && cfg.modelDiscoverModels) {
    compat = {
      reasoning = true;
      thinkingFormat = "chat-template";
      chatTemplateKwargs = {
        thinking = {"$var" = "thinking.enabled";};
        reasoning_effort = {"$var" = "thinking.effort";};
      };
      thinkingLevelMap = piThinkingLevelMap;
    };
  };

  # The model's own body, spelled per harness but shared between the primary model and the
  # optional backup provider - the backup reuses them because its point is serving the same
  # model from another endpoint (see the backupProvider description). Zero costs throughout:
  # nothing behind these gateways is billed, and pi/opencode would otherwise guess a models.dev
  # price for ids they do not know.
  piModelAttrs =
    lib.optionalAttrs (modelLimitContext != null) {
      contextWindow = modelLimitContext;
    }
    // lib.optionalAttrs (modelLimitOutput != null) {
      maxTokens = modelLimitOutput;
    }
    // {
      cost = {
        input = 0;
        output = 0;
        cacheRead = 0;
        cacheWrite = 0;
      };
    }
    // lib.optionalAttrs hasModelThinking {
      reasoning = true;
      thinkingLevelMap = piThinkingLevelMap;
      compat = {
        thinkingFormat = "chat-template";
        chatTemplateKwargs = {
          thinking = {"$var" = "thinking.enabled";};
          # Resolved through thinkingLevelMap, hence the map above is not decoration:
          # it is what turns pi's level into the gateway's reasoning_effort string.
          reasoning_effort = {"$var" = "thinking.effort";};
        };
      };
    };
  ocModelAttrs =
    lib.optionalAttrs hasModelLimits {
      limit =
        {}
        // lib.optionalAttrs (modelLimitContext != null) {
          context = modelLimitContext;
        }
        // lib.optionalAttrs (modelLimitOutput != null) {
          output = modelLimitOutput;
        };
    }
    // {
      cost = {
        input = 0.0;
        output = 0.0;
        cache_read = 0.0;
        cache_write = 0.0;
      };
    }
    // lib.optionalAttrs hasModelThinking {
      # The base options are what a session sends with no variant chosen: thinking on, at
      # the default level. Variants then merge over them.
      options = thinkingKwargs cfg.modelThinkingDefault;
      variants = opencodeVariants;
    };

  # The backup provider's harness-config fragments, empty when backupProvider is unset. Same
  # model body as the primary under the backup's own provider id, endpoint and key placeholder.
  # Extra entries under the harness config's provider MAP (the map itself is assembled in
  # harnessDefs): a plain top-level `{providers = {backup};} // ...` would replace the whole map
  # and drop the primary provider.
  backupPiProviders = lib.optionalAttrs (cfg.backupProvider != null) {
    "${cfg.backupProvider.id}" = {
      baseUrl = cfg.backupProvider.baseUrl;
      api = "openai-completions";
      apiKey = "$PASEO_BACKUP_API_KEY";
      models = [
        ({id = cfg.backupProvider.modelId;} // piModelAttrs)
      ];
    };
  };
  backupOcProviders = lib.optionalAttrs (cfg.backupProvider != null) {
    "${cfg.backupProvider.id}" = {
      npm = "@ai-sdk/openai-compatible";
      name = cfg.backupProvider.label;
      options = {
        baseURL = cfg.backupProvider.baseUrl;
        apiKey = "$PASEO_BACKUP_API_KEY";
      };
      models."${cfg.backupProvider.modelId}" = {name = cfg.backupProvider.modelId;} // ocModelAttrs;
    };
  };
  # The placeholder names the prepare script runs envsubst over - only ones present in the
  # templates, so an unset backup simply never appears in the variable list.
  modelSubstVars =
    "$PASEO_MODEL_API_KEY"
    + lib.optionalString (cfg.backupProvider != null) " $PASEO_BACKUP_API_KEY";

  # One entry per harness the daemon can drive: its CLI lands on the daemon's PATH, and its
  # model config (a store template with a $PASEO_MODEL_API_KEY placeholder - the key itself is
  # substituted into the user's 0600 config at service start, never into the store) points it
  # at cfg.modelBaseUrl under provider name cfg.modelProvider. Enabled individually per user:
  # users.<name>.harnesses.<key>.enable.
  harnessDefs = {
    pi = {
      package = pkgs-unstable.pi-coding-agent;
      configPath = ".pi/agent/models.json";
      # Empty when the model declares no thinking levels: then there is no default to set and pi's
      # settings.json is left entirely alone. Non-empty means one file to deep-merge, at path.
      settings = lib.optionalAttrs hasModelThinking {
        path = ".pi/agent/settings.json";
        file = piSettings;
      };
      config = let
        # Primary + optional backup under one map (backup entries merge at the provider level).
        piProviders =
          {
            "${cfg.modelProvider}" =
              {
                baseUrl = cfg.modelBaseUrl;
                api = "openai-completions";
                apiKey = "$PASEO_MODEL_API_KEY";
                models = [
                  ({id = cfg.modelId;} // piModelAttrs)
                ];
                # When on, the pi-models-discovery extension lists every model the gateway's
                # /v1/models serves (litellm grows this without config edits here); the static
                # entry above stays as the offline fallback. Discovered defaults are zero cost.
              }
              // lib.optionalAttrs cfg.modelDiscoverModels {
                discoverModels = true;
                modelOverrides."${cfg.modelId}" = qwenDiscoveryOverride;
              };
          }
          // backupPiProviders;
      in
        pkgs.writeText "paseo-machine-pi-models.json" (builtins.toJSON {
          "$schema" = "https://pi.dev/schemas/models.schema.json";
          providers = piProviders;
        });
    };
    opencode = {
      package = pkgs-unstable.opencode;
      configPath = ".config/opencode/opencode.json";
      settings = {};
      config = let
        # Primary + optional backup under one map (backup entries merge at the provider level).
        ocProviders =
          {
            "${cfg.modelProvider}" = {
              npm = "@ai-sdk/openai-compatible";
              name = cfg.modelProviderLabel;
              options = {
                baseURL = cfg.modelBaseUrl;
                apiKey = "$PASEO_MODEL_API_KEY";
              };
              models."${cfg.modelId}" = {name = cfg.modelId;} // ocModelAttrs;
            };
          }
          // backupOcProviders;
      in
        pkgs.writeText "paseo-machine-opencode.json" (builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          provider = ocProviders;
          model = "${cfg.modelProvider}/${cfg.modelId}";
        });
    };
  };
  enabledUsers = lib.filterAttrs (_: u: u.enable) cfg.users;
  machineNames = lib.attrNames enabledUsers;

  # Loopback daemon ports, derived so callers don't have to hand-allocate: alphabetical
  # position over the enabled users, starting at PORTS.paseoMachine; a user's own `port`
  # overrides.
  machinePort = name: idx: let
    explicit = enabledUsers.${name}.port;
  in
    if explicit != null
    then explicit
    else config.PORTS.paseoMachine + idx;
  machinePorts = lib.imap0 (i: name: machinePort name i) machineNames;

  # Everything below is per user: paseo-machine-<user> runs the daemon as that user;
  # paseo-machine-<user>-pair mints the pairing link once and registers it on the hub cockpit.
  userModule = name: idx: let
    u = enabledUsers.${name};
    userCfg = config.users.users.${name};
    paseoHome = "${userCfg.home}/.paseo";
    credDir = "${userCfg.home}/.config/paseo/credentials";
    listen = "127.0.0.1:${toString (machinePort name idx)}";
    harnesses = lib.attrNames (lib.filterAttrs (_: h: h.enable) u.harnesses);
    label = "${config.networking.hostName}-${name}";

    # Pre-start, as the user: generate the daemon password on first boot (the shell installer's
    # layout: ~/.config/paseo/credentials/daemon_password, 0600) and (re-)write each enabled
    # harness's model config with the key substituted - copy-if-changed, so daemon AND
    # interactive shells keep seeing a working config while the key never touches the store.
    prepare = pkgs.writeShellScript "paseo-machine-${name}-prepare" ''
      set -eu
      umask 077
      mkdir -p "${credDir}"
      if [ ! -s "${credDir}/daemon_password" ]; then
        openssl rand -hex 24 >"${credDir}/daemon_password"
      fi
      export PASEO_MODEL_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/model_api_key")"
      ${lib.optionalString (cfg.backupProvider != null) ''
          export PASEO_BACKUP_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/backup_api_key")"''}
      ${lib.concatMapStrings (h: let
          d = harnessDefs.${h};
          s = d.settings;
        in ''
          mkdir -p "$(dirname "${userCfg.home}/${d.configPath}")"
          envsubst '${modelSubstVars}' <${d.config} >"${userCfg.home}/${d.configPath}.tmp"
          if ! cmp -s "${userCfg.home}/${d.configPath}.tmp" "${userCfg.home}/${d.configPath}" 2>/dev/null; then
            mv -f "${userCfg.home}/${d.configPath}.tmp" "${userCfg.home}/${d.configPath}"
          else
            rm -f "${userCfg.home}/${d.configPath}.tmp"
          fi
          ${lib.optionalString (s != {}) ''
            # pi's startup thinking level, deep-merged into a file pi also owns and writes: the
            # user's own keys survive, the ones we name are asserted, and pi re-asserts them on
            # every daemon start (so a level saved with Ctrl+S lasts until the next restart). An
            # unparseable file is set aside rather than eaten.
            #
            # packages gets list-appended rather than deep-merged - jq's * operator replaces
            # arrays wholesale, which would eat packages the user installs with `pi install`.
            s_target="${userCfg.home}/${s.path}"
            s_dir="$(dirname "$s_target")"
            mkdir -p "$s_dir"
            chmod 700 "$s_dir" 2>/dev/null || true
            s_tmp="$s_dir/.paseo-${h}-settings.tmp"
            if [ -s "$s_target" ] && ! ${pkgs.jq}/bin/jq -e . "$s_target" >/dev/null 2>&1; then
              cp -f "$s_target" "$s_target.paseo-backup"
              cp ${s.file} "$s_tmp"
            elif [ -s "$s_target" ] && ${pkgs.jq}/bin/jq -s '((.[0] * .[1]) + (if ((.[0].packages // []) | length) == 0 and ((.[1].packages // []) | length) == 0 then {} else {packages: ((.[0].packages // []) + (.[1].packages // []) | unique_by(if type == "object" then .source else . end))} end))' "$s_target" ${s.file} >"$s_tmp"; then
              :
            else
              cp ${s.file} "$s_tmp"
            fi
            if cmp -s "$s_tmp" "$s_target" 2>/dev/null; then
              rm -f "$s_tmp"
            else
              chmod 0600 "$s_tmp"
              mv -f "$s_tmp" "$s_target"
            fi
          ''}
        '')
        harnesses}
    '';

    # The daemon password is read at start from the user-owned credential file - not baked into
    # the unit (Environment= is readable through systemctl show) and not into the store. The
    # model key goes into the daemon's env so the harness children it spawns inherit it.
    start = pkgs.writeShellScript "paseo-machine-${name}-start" ''
      set -eu
      export PASEO_PASSWORD="$(cat "${credDir}/daemon_password")"
      if [ -f "$CREDENTIALS_DIRECTORY/model_api_key" ]; then
        export PASEO_MODEL_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/model_api_key")"
      fi
      ${lib.optionalString (cfg.backupProvider != null) ''
        if [ -f "$CREDENTIALS_DIRECTORY/backup_api_key" ]; then
          export PASEO_BACKUP_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/backup_api_key")"
        fi''}
      exec ${paseoCli}/bin/paseo daemon run
    '';

    # One-shot registration, the declarative twin of the installer's step 5: mint a single-use
    # pairing offer over loopback, then POST {token, name, url, profile} to the hub's register
    # endpoint - the profile makes the machine join every dashboard through the hub's host sync
    # without a click. Runs once per marker, so reboots/rebuilds don't spam the cockpit's
    # waiting list. Re-mint with:
    #   rm /var/lib/paseo-machine-${name}/registered && systemctl restart paseo-machine-${name}-pair
    pair = pkgs.writeShellScript "paseo-machine-${name}-pair" ''
      set -uo pipefail
      marker="$STATE_DIRECTORY/registered"
      if [ -s "$marker" ]; then
        echo "already registered: $(cat "$marker")"
        exit 0
      fi
      PASEO_PASSWORD="$(cat "${credDir}/daemon_password")"
      export PASEO_HOME="${paseoHome}" PASEO_PASSWORD
      # /api/health answers before the WS layer finishes warming (early attempts 503) - retry
      # the pairing call itself, same trap packages/paseo/machine/install.sh documents.
      url=""
      for _ in $(seq 1 30); do
        url="$(${paseoCli}/bin/paseo --host "tcp://${listen}" daemon pair --json 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.url // empty' || true)"
        [ -n "$url" ] && break
        sleep 2
      done
      if [ -z "$url" ]; then
        echo "paseo pair got no URL after 60s (daemon unreachable at ${listen}?)" >&2
        exit 1
      fi
      PROFILE="$(PAIR_URL="$url" DAEMON_PASSWORD="$PASEO_PASSWORD" MNAME="${label}" \
        ${pkgs.nodejs}/bin/node -e 'const o=JSON.parse(Buffer.from((process.env.PAIR_URL.split("#offer=")[1]||"").replace(/-/g,"+").replace(/_/g,"/"),"base64").toString());process.stdout.write(JSON.stringify({serverId:o.serverId,label:process.env.MNAME,password:process.env.DAEMON_PASSWORD,connections:[{type:"relay",relayEndpoint:o.relay.endpoint,useTls:o.relay.useTls!==false,daemonPublicKeyB64:o.daemonPublicKeyB64}],createdAt:new Date().toISOString()}))' 2>/dev/null || true)"
      body="$(jq -n --arg token "$(cat "$CREDENTIALS_DIRECTORY/enrollment_token")" \
        --arg name "${label}" --arg url "$url" \
        --argjson profile "''${PROFILE:-null}" \
        '{token: $token, name: $name, url: $url} + (if $profile == null then {} else {profile: $profile} end)')"
      if ! curl -fsS -m 15 -X POST -H 'content-type: application/json' --data "$body" \
        "${cfg.hubUrl}/paseo-api/register"; then
        echo "cockpit registration at ${cfg.hubUrl}/paseo-api/register failed - pair manually: paseo daemon pair" >&2
        exit 1
      fi
      printf '%s' "$url" >"$marker"
      chmod 600 "$marker"
      echo "registered on the cockpit as ${label}"
    '';
  in {
    systemd.tmpfiles.rules = [
      "d ${paseoHome} 0700 ${name} ${userCfg.group} - -"
      # The parent of credDir must be declared too: tmpfiles creates undeclared intermediates
      # root-owned, and then the akos-run prepare script cannot mkdir inside them.
      "d ${userCfg.home}/.config/paseo 0700 ${name} ${userCfg.group} - -"
      "d ${credDir} 0700 ${name} ${userCfg.group} - -"
    ];

    systemd.services."paseo-machine-${name}" = {
      description = "Paseo harness machine (${lib.concatStringsSep "+" harnesses}, user ${name})";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # ps: the daemon's provider process-tree watcher (spawn ps --ppid ...) crashes the worker
      # without it; git/openssh: harness parity with the hub daemon's PATH; nodejs_24: the
      # harness CLIs run on node (bin/paseo pins its own).
      path =
        [pkgs.git pkgs.gettext pkgs.nodejs_24 pkgs.openssh pkgs.openssl pkgs.procps pkgs.which]
        ++ map (h: harnessDefs.${h}.package) harnesses;
      environment = {
        PASEO_HOME = paseoHome;
        PASEO_LISTEN = listen;
        # Loopback port with no URL in front: the dashboard is reached through the relay, the
        # local UI would be dead weight (same choice as the hub's hermes daemon).
        PASEO_WEB_UI_ENABLED = "false";
        PASEO_RELAY_ENABLED = "true";
        PASEO_RELAY_ENDPOINT = cfg.relayEndpoint;
        PASEO_RELAY_PUBLIC_ENDPOINT = cfg.relayEndpoint;
        PASEO_RELAY_USE_TLS = "true";
        PASEO_RELAY_PUBLIC_USE_TLS = "true";
        HOME = userCfg.home;
      };
      serviceConfig = {
        ExecStartPre = "${prepare}";
        ExecStart = "${start}";
        User = name;
        Group = userCfg.group;
        Restart = "always";
        RestartSec = 5;
        LoadCredential =
          ["model_api_key:${config.sops.secrets.${cfg.modelApiKeySecret}.path}"]
          ++ lib.optional
          (cfg.backupProvider != null)
          "backup_api_key:${config.sops.secrets.${cfg.backupProvider.apiKeySecret}.path}";
        NoNewPrivileges = true;
        PrivateTmp = true;
        # Deliberately NOT ProtectSystem=strict / ProtectHome: the daemon writes ~/.paseo and
        # the harness configs and spawns arbitrary build commands in the user's home (the
        # installer's own unit says the same, with an incident behind it).
        UMask = "0077";
      };
    };

    systemd.services."paseo-machine-${name}-pair" = {
      description = "Register the ${name} Paseo machine on the hub cockpit";
      wantedBy = ["multi-user.target"];
      after = ["paseo-machine-${name}.service" "network-online.target"];
      wants = ["network-online.target"];
      requires = ["paseo-machine-${name}.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = name;
        Group = userCfg.group;
        LoadCredential = ["enrollment_token:${config.sops.secrets."paseo/enrollment_token".path}"];
        StateDirectory = "paseo-machine-${name}";
      };
      path = [pkgs.curl pkgs.jq pkgs.nodejs];
      script = "${pair}";
    };
  };
in {
  options.MODULES.services.paseo-machine = {
    enable = mkEnableOption ''
      Paseo harness machines as NixOS services: one Paseo daemon per listed user, running as
      that user, dialing out to the hub's relay and registering itself on the hub's cockpit
      automatically - the declarative twin of the /install/<token>/<harness>.sh scripts
      (packages/paseo/machine/RUNBOOK-paseo-machine.md). Harnesses are enabled individually per
      user via users.<name>.harnesses.<harness>.enable.
    '';

    relayEndpoint = mkOption {
      type = types.str;
      default = "${hubFqdn}:${toString config.PORTS.paseoRelayFunnel}";
      description = "host:port of the hub's public relay (Tailscale Funnel on hp).";
    };

    hubUrl = mkOption {
      type = types.str;
      default = "https://${hubFqdn}:8443";
      description = "Cockpit origin; /paseo-api/register takes the pairing link + host profile.";
    };

    modelBaseUrl = mkOption {
      type = types.str;
      default = "${cfg.hubUrl}/litellm/v1";
      defaultText = lib.literalExpression "hubUrl + \"/litellm/v1\"";
      description = ''
        OpenAI-compatible endpoint baked into the harness model configs: the hub's LiteLLM gateway,
        on the public Funnel path its MODULES.services.litellm.public option registers (the same
        URL the generated /install/<token>/machine.sh scripts carry). Derived from `hubUrl` so a
        fleet pointed at another hub takes its models with it; that hub must have the public path
        enabled or every agent fails its first request.

        A machine that is itself on the tailnet can skip the trip through the Funnel and use the
        hub's own subdomain instead - modelBaseUrl = "https://litellm.hp/v1", which is what legion5
        sets to stay byte-identical with the interactive configs there.
      '';
    };

    modelProvider = mkOption {
      type = types.str;
      default = "litellm";
      description = ''
        Provider id under which the model is registered in the harness configs, i.e. the
        "<provider>" half of the model reference (pi --model <provider>/<id>, opencode's
        model setting). Set it to the same id a host's interactive setup uses so harness
        configs and daily use agree on one provider entry - which is what "litellm" is here:
        the gateway is the endpoint these machines talk to, whoever answers behind it.
      '';
    };

    modelProviderLabel = mkOption {
      type = types.str;
      default = "LiteLLM (hp)";
      description = "Display name for the provider (opencode's picker).";
    };

    modelApiKeySecret = mkOption {
      type = types.str;
      default = "paseo/enrollment_api_key";
      example = "opencode/litellm_api_key";
      description = ''
        sops secret holding the model API key. Declared here (merging with any other module's
        declaration of the same key), handed to the daemon through LoadCredential and baked
        into the user's harness configs by the pre-start script.

        It has to be a key the gateway accepts, since that is what these configs now point at -
        either its master key or (better, on a machine that only ever needs one model) a virtual
        key minted on it. On a host whose interactive setup already declares a LiteLLM key, point
        this at that secret instead of adding a second one; the example is legion5's.
      '';
    };

    modelId = mkOption {
      type = types.str;
      default = "futurelab/qwen3.8-flash-next";
      description = ''
        Model offered to the harnesses, spelled the way the gateway spells it: a LiteLLM
        `model_name`, vendor prefix included ("futurelab/..." is the wildcard Aqueduct deployment
        in litellm.nix). So the reference a user types is <modelProvider>/<modelId>, two prefixes
        deep - both harnesses take that, and users/akos.nix already does the same interactively.
      '';
    };

    modelContextLength = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 262144;
      description = ''
        Context window of cfg.modelId in tokens - what the gateway behind modelBaseUrl actually
        serves. Written as pi's contextWindow and opencode's limit.context. Set it next to
        modelId, for the model it names: null (the default) writes neither field and leaves the
        harnesses guessing, and pi guesses 128000, which makes it compact its history at ~111K
        instead of using the window it was handed. Same number users/akos.nix gives the
        interactive opencode entry for the same model.
      '';
    };

    modelOutputLength = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 32768;
      description = ''
        Max output tokens of cfg.modelId: pi's maxTokens, opencode's limit.output. pi guesses
        16384 when unset, which caps every answer and truncates long tool-call arguments (pi
        fails such a call rather than resume it). Keep it well under modelContextLength.
      '';
    };

    modelThinkingLevels = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["low" "medium" "xhigh"];
      description = ''
        Thinking levels cfg.modelId accepts, weakest first, spelled the way the gateway spells
        reasoning_effort (pi's own level keys: minimal, low, medium, high, xhigh, max - "off" is
        implied and never listed). The last entry is the level a harness starts on.

        Empty (the default) means the model is declared as non-reasoning: pi reports thinking
        "no" and opencode gets no variants. Set it per model, never as a default - a level the
        gateway does not implement is a request it rejects.
      '';
    };

    modelThinkingDefault = mkOption {
      type = types.str;
      default = "xhigh";
      example = "medium";
      description = ''
        Thinking level a session starts on for cfg.modelId, when modelThinkingLevels is non-empty:
        opencode's base model options (what it sends until a variant is chosen) and the startup
        level pi reads from its settings.json under modelThinkingLevels."<provider>/<modelId>".
        Both harnesses still let the user change it per session (/thinking, opencode's variant
        picker); pi re-asserts this level on every daemon start, so a level saved there with Ctrl+S
        lasts until then. Must be one of modelThinkingLevels.
      '';
    };

    modelDiscoverModels = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Fetch the pi model list from the gateway instead of the static catalog: adds
        "discoverModels": true to the pi provider entry, which makes the official
        pi-models-discovery extension (pulled from npm via the settings.json packages fragment)
        GET {baseUrl}/models and register every model it serves. The gateway's model list then
        grows without editing this module; litellm.nix's dashboard-only model additions pick up
        automatically.

        Defaults of the discovered entries: zero cost, reasoning on with pi's standard levels
        (xhigh/max pinned off), 1M context. modelOverrides re-asserts the curated thinking
        configuration for cfg.modelId, and the static catalog entry stays as the offline
        fallback for when the gateway is unreachable. opencode has no such feature for custom
        OpenAI-compatible providers, so this is pi-only.
      '';
    };

    backupProvider = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          id = mkOption {
            type = types.str;
            default = "futurelab";
            description = "Provider id the backup registers under in the harness configs.";
          };

          label = mkOption {
            type = types.str;
            default = "FutureLab (Aqueduct)";
            description = "Display name for the backup provider (opencode's picker).";
          };

          baseUrl = mkOption {
            type = types.str;
            example = "https://futurelab.robo4you.at/v1";
            description = "OpenAI-compatible endpoint the backup provider talks to.";
          };

          apiKeySecret = mkOption {
            type = types.str;
            example = "futurelab_api_key";
            description = ''
              sops secret holding the backup key, handed to the daemon through LoadCredential as
              PASEO_BACKUP_API_KEY and baked into the harness configs next to the primary key.
            '';
          };

          modelId = mkOption {
            type = types.str;
            default = "qwen3.8-flash-next";
            description = ''
              Model id on the backup gateway, spelled the way THAT gateway wants it (the futurelab
              Aqueduct one takes the bare name - "futurelab/..." is only LiteLLM's wildcard
              spelling on hp).
            '';
          };
        };
      });
      default = null;
      example = lib.literalExpression ''
        {
          baseUrl = "https://futurelab.robo4you.at/v1";
          apiKeySecret = "futurelab_api_key";
        }
      '';
      description = ''
        Optional second provider registered next to the primary one in every harness config: a
        fallback to switch to by hand when the primary (the hub's LiteLLM gateway) is down.
        Nothing in pi or opencode fails over automatically - the user picks the backup in the
        model selector.

        The backup's model entry reuses the primary's settings (modelContextLength,
        modelOutputLength, modelThinkingLevels, modelThinkingDefault, zero cost), which is only
        correct when the backup serves the same model the primary does - the intended shape: the
        same qwen3.8-flash-next that litellm.nix's futurelabEnable wildcard proxies on hp, dialled
        straight to the Aqueduct gateway instead while hp is unreachable.
      '';
    };

    users = mkOption {
      type = types.attrsOf (types.submodule (_: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Run a Paseo daemon as this user.";
          };
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = ''
              Loopback port for this user's daemon. Default: PORTS.paseoMachine plus the user's
              alphabetical index among the enabled users.
            '';
          };
          harnesses = mkOption {
            type = types.attrsOf (types.submodule (_: {
              options.enable = mkOption {
                type = types.bool;
                default = true;
                description = "Install this harness CLI into the daemon's PATH and configure it.";
              };
            }));
            default = {};
            example = lib.literalExpression "{ pi.enable = true; opencode.enable = true; }";
            description = ''
              Harnesses this user's daemon can drive, enabled individually. Valid keys:
              ${lib.concatStringsSep ", " (lib.attrNames harnessDefs)}.
            '';
          };
        };
      }));
      default = {};
      description = "Users to run a Paseo harness-machine daemon for.";
    };
  };

  config = mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = config.MODULES.security.sops.enable;
            message = "MODULES.services.paseo-machine needs MODULES.security.sops.enable: the model key and the hub enrollment token come from sops.";
          }
          {
            assertion = lib.length (lib.unique machinePorts) == lib.length machinePorts;
            message = "paseo-machine loopback ports collide: ${lib.concatStringsSep ", " (map toString machinePorts)} - override users.<name>.port.";
          }
          {
            assertion = thinkingDefaultListed;
            message = "MODULES.services.paseo-machine.modelThinkingDefault = ${cfg.modelThinkingDefault} is not in modelThinkingLevels (${lib.concatStringsSep ", " cfg.modelThinkingLevels}) - a level the gateway never advertised is a request it rejects.";
          }
        ]
        ++ lib.mapAttrsToList (name: _: {
          assertion = config.users.users ? ${name};
          message = "MODULES.services.paseo-machine.users.${name}: no such user in config.users.users.";
        })
        enabledUsers
        ++ lib.mapAttrsToList (name: u: let
          hs = lib.attrNames (lib.filterAttrs (_: h: h.enable) u.harnesses);
        in {
          assertion = hs != [] && lib.all (h: lib.elem h (lib.attrNames harnessDefs)) hs;
          message = "MODULES.services.paseo-machine.users.${name}.harnesses: enable at least one of ${lib.concatStringsSep "/" (lib.attrNames harnessDefs)} (got: ${lib.concatStringsSep ", " hs}).";
        })
        enabledUsers;

      # Same sops keys the hub publishes installers with; on hp itself paseo.nix declares
      # them already - an empty second declaration merges, it does not clash. The model key
      # follows cfg.modelApiKeySecret (e.g. opencode/litellm_api_key on hosts where the
      # opencode module already declares it with a user owner - LoadCredential reads it as
      # PID1, so any owner works).
      sops.secrets =
        {
          "paseo/enrollment_token" = {};
          "${cfg.modelApiKeySecret}" = {};
        }
        // lib.optionalAttrs (cfg.backupProvider != null) {
          "${cfg.backupProvider.apiKeySecret}" = {};
        };

      # Base of the derived per-user loopback daemon ports (see machinePort).
      PORTS.paseoMachine = 8117;
    }

    # Important: the per-user fragments are generated inside the *values* of systemd.*, not in
    # the module spine. Computing machineNames needs the final value of cfg.users, and resolving
    # the users option needs this module's `config` evaluated - generating them in the spine (or
    # in the top-level let) closes that into infinite recursion. Down here, machineNames is only
    # forced when the module system actually descends into systemd.services / tmpfiles.rules.
    {
      systemd.services =
        lib.foldl' (acc: f: acc // f.systemd.services) {}
        (lib.imap0 (i: name: userModule name i) machineNames);
      systemd.tmpfiles.rules =
        lib.concatLists
        (lib.imap0 (i: name: (userModule name i).systemd.tmpfiles.rules) machineNames);
    }
  ]);
}
