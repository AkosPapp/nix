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

  # One entry per harness the daemon can drive: its CLI lands on the daemon's PATH, and its
  # model config (a store template with a $PASEO_MODEL_API_KEY placeholder - the key itself is
  # substituted into the user's 0600 config at service start, never into the store) points it
  # at cfg.modelBaseUrl under provider name cfg.modelProvider. Enabled individually per user:
  # users.<name>.harnesses.<key>.enable.
  harnessDefs = {
    pi = {
      package = pkgs-unstable.pi-coding-agent;
      configPath = ".pi/agent/models.json";
      config = pkgs.writeText "paseo-machine-pi-models.json" (builtins.toJSON {
        "$schema" = "https://pi.dev/schemas/models.schema.json";
        providers."${cfg.modelProvider}" = {
          baseUrl = cfg.modelBaseUrl;
          api = "openai-completions";
          apiKey = "$PASEO_MODEL_API_KEY";
          models = [
            {id = cfg.modelId;}
          ];
        };
      });
    };
    opencode = {
      package = pkgs-unstable.opencode;
      configPath = ".config/opencode/opencode.json";
      config = pkgs.writeText "paseo-machine-opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        provider."${cfg.modelProvider}" = {
          npm = "@ai-sdk/openai-compatible";
          name = cfg.modelProviderLabel;
          options = {
            baseURL = cfg.modelBaseUrl;
            apiKey = "$PASEO_MODEL_API_KEY";
          };
          models."${cfg.modelId}" = {
            name = cfg.modelId;
          };
        };
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
      ${lib.concatMapStrings (h: let
          d = harnessDefs.${h};
        in ''
          mkdir -p "$(dirname "${userCfg.home}/${d.configPath}")"
          envsubst '$PASEO_MODEL_API_KEY' <${d.config} >"${userCfg.home}/${d.configPath}.tmp"
          if ! cmp -s "${userCfg.home}/${d.configPath}.tmp" "${userCfg.home}/${d.configPath}" 2>/dev/null; then
            mv -f "${userCfg.home}/${d.configPath}.tmp" "${userCfg.home}/${d.configPath}"
          else
            rm -f "${userCfg.home}/${d.configPath}.tmp"
          fi
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
        LoadCredential = ["model_api_key:${config.sops.secrets.${cfg.modelApiKeySecret}.path}"];
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
      sops.secrets = {
        "paseo/enrollment_token" = {};
        "${cfg.modelApiKeySecret}" = {};
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
