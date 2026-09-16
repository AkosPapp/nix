{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.hermes-agent;
  vllm = config.MODULES.services.vllm;
  hermes = config.services.hermes-agent;

  instance = vllm.instances.${cfg.model} or null;

  # Catalogue key -> the context window Hermes is told, for the default model and every extra
  # one. Only evaluated for keys the assertions below have confirmed this host serves.
  providerContexts =
    {${cfg.model} = instance.model.maxModelLen;}
    // lib.mapAttrs (name: m:
      if m.contextLength != null
      then m.contextLength
      else vllm.instances.${name}.model.maxModelLen)
    cfg.extraModels;

  missingExtraModels = lib.filter (name: !(vllm.instances ? ${name})) (lib.attrNames cfg.extraModels);

  stateDir = hermes.stateDir;

  # Shared secret between the backend service and the desktop app. Generated on the machine
  # rather than kept in sops: nothing outside this host ever needs it, and a fresh install gets
  # one without anyone having to add a secret first.
  tokenFile = "${stateDir}/dashboard-session-token";

  backendUrl = "http://${hermes.backend.host}:${toString hermes.backend.port}";

  # Same launcher wiring upstream's Home Manager module does. A menu launcher reads no shell
  # profile, so without HERMES_HOME the app would open ~/.hermes - the unconfigured state that
  # triggers the provider wizard - instead of the service's. The token is read at launch, never
  # baked in with --set, because makeWrapper writes --set values into the world-readable store.
  desktopPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop.override {
    extraEnv =
      {
        HERMES_HOME = "${stateDir}/.hermes";
        # Makes the app refuse config edits and point at nixos-rebuild instead, since this
        # module owns config.yaml and would overwrite them.
        inherit (config.systemd.services.hermes-agent.environment) HERMES_MANAGED;
      }
      // lib.optionalAttrs cfg.dashboard {
        HERMES_DESKTOP_REMOTE_URL = backendUrl;
      };
    extraRun = lib.optional cfg.dashboard ''
      if [ -r ${tokenFile} ]; then
        HERMES_DESKTOP_REMOTE_TOKEN="$(tr -d '\r\n' < ${tokenFile})"
        export HERMES_DESKTOP_REMOTE_TOKEN
      else
        echo "hermes-desktop: cannot read ${tokenFile} - log out and back in so the hermes group applies." >&2
      fi
    '';
  };
in {
  options.MODULES.services.hermes-agent = {
    enable = mkEnableOption "Hermes Agent, backed by this host's own vLLM";

    model = mkOption {
      type = types.str;
      default = "coder";
      description = ''
        Catalogue key of the MODULES.services.vllm instance Hermes talks to. It connects to that
        instance's port on loopback directly rather than through LiteLLM, so it keeps working
        while hp (the gateway) is down, and it never gets load-balanced onto another host's
        slower replica of the same name.

        The model must serve at least 64K tokens of context (`maxModelLen`), or Hermes refuses to
        start a session with it, and must be started with tool calling enabled.
      '';
    };

    extraModels = mkOption {
      type = types.attrsOf (types.submodule {
        options.contextLength = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 65536;
          description = ''
            Context window Hermes is told this model has. Null uses the instance's real
            `maxModelLen`. Setting it higher than that is how a model below Hermes' 64K floor gets
            past the check at all - Hermes then plans prompts for the stated window and vLLM
            rejects every request that exceeds the real one, so it only suits short sessions.
          '';
        };
      });
      default = {};
      example = lib.literalExpression ''{ heretic.contextLength = 65536; }'';
      description = ''
        Further MODULES.services.vllm instances on this host to offer in Hermes next to `model`,
        each as a named custom provider of the same name. `model` stays the default; switch
        mid-session with `/model custom:<name>:<name>`, and back with
        `/model custom:<model>:<model>`. Like `model`, these connect to the instance directly,
        not through LiteLLM.
      '';
    };

    users = mkOption {
      type = types.listOf types.str;
      default = ["akos"];
      description = ''
        Interactive users added to the hermes group, so the `hermes` CLI and the desktop app
        they run share the service's HERMES_HOME (config, sessions, skills, memory) instead of
        starting from an empty ~/.hermes. The upstream module only does this in container mode.
        Group membership applies from the next login.
      '';
    };

    dashboard = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run `hermes dashboard`: the web UI, plus the backend API the desktop app attaches to.
        Bound to loopback on PORTS.hermesDashboard, so it is a browser tab on this machine
        only. It cannot simply be put behind tailscale serve or Traefik - the server rejects
        any Host header other than the address it bound to, as a DNS-rebinding defence.
      '';
    };

    desktop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install Hermes Desktop (the Electron app) with a menu entry. With `dashboard` on it
        attaches to the service's backend instead of starting a private one, so the CLI, the
        web UI and the app all see the same sessions.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = vllm.enable && instance != null;
        message = "MODULES.services.hermes-agent.model = \"${cfg.model}\" is not a model MODULES.services.vllm serves on this host.";
      }
      {
        assertion = instance == null || (instance.model.maxModelLen or 0) >= 64000;
        message = "MODULES.services.hermes-agent: vLLM model \"${cfg.model}\" needs maxModelLen >= 64000; Hermes rejects smaller context windows at session start.";
      }
      {
        assertion = missingExtraModels == [];
        message = "MODULES.services.hermes-agent.extraModels names models MODULES.services.vllm does not serve on this host: ${lib.concatStringsSep ", " missingExtraModels}";
      }
      {
        assertion = missingExtraModels != [] || lib.all (ctx: ctx >= 64000) (lib.attrValues providerContexts);
        message = "MODULES.services.hermes-agent.extraModels: every model needs a context window >= 64000 (its maxModelLen, or contextLength to override it); Hermes rejects smaller ones at session start.";
      }
    ];

    # A stated window larger than the served one gets past Hermes' check but not past vLLM, so
    # say so at build time rather than leaving it to surface as a mid-session context error.
    warnings = lib.optionals (missingExtraModels == []) (lib.concatLists (lib.mapAttrsToList (name: m:
      lib.optional (m.contextLength != null && m.contextLength > vllm.instances.${name}.model.maxModelLen)
      "MODULES.services.hermes-agent: \"${name}\" is presented to Hermes with ${toString m.contextLength} tokens of context but vLLM serves ${toString vllm.instances.${name}.model.maxModelLen}; requests past the real window will be rejected.")
    cfg.extraModels));

    PORTS.hermesDashboard = 9119;

    services.hermes-agent = {
      enable = true;
      # Puts `hermes` on PATH and exports HERMES_HOME system-wide, so the CLI and the service
      # share one state directory. Both only reach a session started after the rebuild - an
      # already-open shell still falls back to ~/.hermes and offers the setup wizard.
      addToSystemPackages = true;

      settings.model = {
        provider = "custom";
        # The public port: in lazy mode it is the socket that wakes the container, so the first
        # request after an idle period blocks while the model loads instead of being refused.
        base_url = "http://127.0.0.1:${toString instance.port}/v1";
        default = instance.model.servedName;
        # Stated rather than probed. Hermes otherwise asks /v1/models, which in lazy mode means
        # waiting out a cold model load at startup, and falls back to a family guess if that
        # times out.
        context_length = instance.model.maxModelLen;
      };

      # One named custom provider per model, the default included, so `/model custom:<name>:<name>`
      # can move between them in both directions. The entry-level context_length is what Hermes
      # re-resolves on a /model switch (model.context_length above only covers the default), so
      # it is the value the 64K floor is checked against after switching. No key: Hermes sends
      # "no-key-required" to a custom endpoint without one, and vLLM checks none.
      settings.providers =
        lib.mapAttrs (name: ctx: {
          api = "http://127.0.0.1:${toString vllm.instances.${name}.port}/v1";
          default_model = vllm.instances.${name}.model.servedName;
          context_length = ctx;
        })
        providerContexts;

      backend = mkIf cfg.dashboard {
        mode = "dashboard";
        port = config.PORTS.hermesDashboard;
        sessionTokenFile = tokenFile;
      };
    };

    # Creates the session token once and keeps it: regenerating it on every boot would
    # disconnect a desktop app that read the previous one. 0640 hermes:hermes, so the backend
    # (running as hermes) and members of the group (the desktop launcher) can read it and no one
    # else can.
    systemd.services.hermes-dashboard-token = mkIf cfg.dashboard {
      description = "Generate the Hermes dashboard session token";
      before = ["hermes-backend.service"];
      requiredBy = ["hermes-backend.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -s ${tokenFile} ]; then
          umask 0137
          ${pkgs.openssl}/bin/openssl rand -hex 32 > ${tokenFile}
        fi
        chown ${hermes.user}:${hermes.group} ${tokenFile}
        chmod 0640 ${tokenFile}
      '';
    };

    environment.systemPackages = lib.optional cfg.desktop desktopPackage;

    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = [hermes.group];
    });
  };
}
