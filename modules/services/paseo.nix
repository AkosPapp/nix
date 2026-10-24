{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.paseo;
  traefik = config.MODULES.networking.traefik;

  paseoCli = pkgs.callPackage ../../packages/paseo/cli.nix {};
  paseoRelay = pkgs.callPackage ../../packages/paseo/relay.nix {};

  # The hub's static logo, straight out of the daemon's bundled web UI (what it serves at
  # <hub>/favicon.ico - there is no favicon.svg there: that path falls through to the SPA's
  # index.html). The app swaps its own tab favicon for state variants (favicon-dark-running
  # etc.) at runtime, so this plain one is the only sane static icon; the cockpit page and the
  # homepage tiles use it.
  paseoFavicon = "${paseoCli}/lib/node_modules/@getpaseo/cli/node_modules/@getpaseo/server/dist/server/web-ui/favicon.ico";

  # The same icon as a URL, for things that fetch it over HTTP (homepage tiles).
  paseoFaviconUrl = "${traefik.urlOf "paseo"}/favicon.ico";

  # The ONLY publicly reachable Paseo component. host:port because the daemon/clients build
  # `wss://<endpoint>/ws` and the path is protocol-fixed (protocol/src/daemon-endpoints.ts);
  # there is no way to hang the relay off the shared 8443 funnel under a sub-path, so it gets
  # Funnel's third allowed port (10000, freed when outline.nix retired).
  relayPublicHost = "${config.networking.fqdn}:${toString config.PORTS.paseoRelayFunnel}";

  webDir = "/var/lib/paseo-web";

  # What the model can do, spelled per harness - the same facts MODULES.services.paseo-machine
  # declares for machines configured with Nix, baked into the installer here so a curl-piped machine
  # describes the model identically. Neither harness asks the endpoint: pi and opencode read these
  # out of their own config files and guess when a field is missing, and pi's guess (128000/16384)
  # costs ~150K of window in early compaction while the missing `reasoning` flag makes /thinking
  # offer nothing at all.
  #
  #   limit      pi: contextWindow / maxTokens      opencode: limit.context / limit.output
  #   thinking   pi: reasoning + thinkingLevelMap   opencode: options + variants
  #              + compat.chatTemplateKwargs        (pi's startup level: settings.json)
  #
  # These describe model.<id>, which defaults to the futurelab model the hub serves: changing
  # model.id means restating them (or emptying thinkingLevels for a model that cannot think).
  hasModelLimits = cfg.model.contextLength != null || cfg.model.outputLength != null;
  hasModelThinking = cfg.model.thinkingLevels != [];
  # A startup level only makes sense among the levels the model lists: defaulting a low/medium-only
  # model to xhigh would make every installed machine open with a request the gateway rejects.
  thinkingDefaultListed =
    !hasModelThinking || lib.elem cfg.model.thinkingDefault cfg.model.thinkingLevels;

  # pi's seven level keys, all present: a level the model does not offer is null, which is how pi
  # hides it - including "off": null, pi's spelling of "off sends no effort field at all".
  piThinkingLevelJson = builtins.toJSON (lib.genAttrs
    ["off" "minimal" "low" "medium" "high" "xhigh" "max"]
    (l:
      if l != "off" && lib.elem l cfg.model.thinkingLevels
      then l
      else null));
  # The gateway takes thinking as vLLM-style chat_template_kwargs. pi only puts them on the wire
  # when compat.thinkingFormat says which dialect, and the $var forms are resolved through
  # thinkingLevelMap - which is why that map is not decoration. The backslashes are for the shell
  # heredoc this lands in: the file must end up saying "$var".
  piCompatJson = ''{"thinkingFormat": "chat-template", "chatTemplateKwargs": {"thinking": {"\$var": "thinking.enabled"}, "reasoning_effort": {"\$var": "thinking.effort"}}}'';
  # opencode's base options are what a session sends until a variant is chosen: thinking on, at the
  # default level. Variants merge over them, so "off" has to clear the base flag too.
  ocOptionsJson = builtins.toJSON {
    chat_template_kwargs = {
      thinking = true;
      reasoning_effort = cfg.model.thinkingDefault;
    };
  };
  ocVariantsJson = builtins.toJSON ({
      off = {
        enable_thinking = false;
        chat_template_kwargs.thinking = false;
      };
    }
    // lib.genAttrs cfg.model.thinkingLevels (e: {
      chat_template_kwargs = {
        thinking = true;
        reasoning_effort = e;
      };
    }));

  # One-line model entries, matching the compact style of the heredocs below. $MODEL_ID stays a
  # shell placeholder: the installer learns the model from the hub, it does not hard-code it.
  piModelJson =
    "{"
    + lib.concatStringsSep ", " (
      ["\"id\": \"$MODEL_ID\""]
      ++ lib.optionals (cfg.model.contextLength != null) [
        "\"contextWindow\": ${toString cfg.model.contextLength}"
      ]
      ++ lib.optionals (cfg.model.outputLength != null) [
        "\"maxTokens\": ${toString cfg.model.outputLength}"
      ]
      ++ lib.optionals hasModelThinking [
        "\"reasoning\": true"
        "\"thinkingLevelMap\": ${piThinkingLevelJson}"
        "\"compat\": ${piCompatJson}"
      ]
    )
    + "}";
  ocModelJson =
    "{"
    + lib.concatStringsSep ", " (
      ["\"name\": \"$MODEL_ID\""]
      ++ lib.optionals hasModelLimits [
        "\"limit\": ${
          builtins.toJSON (
            {}
            // lib.optionalAttrs (cfg.model.contextLength != null) {
              context = cfg.model.contextLength;
            }
            // lib.optionalAttrs (cfg.model.outputLength != null) {
              output = cfg.model.outputLength;
            }
          )
        }"
      ]
      ++ lib.optionals hasModelThinking [
        "\"options\": ${ocOptionsJson}"
        "\"variants\": ${ocVariantsJson}"
      ]
    )
    + "}";

  # Non-secret install parameters; the two secrets (enrollment token -> URL segment + model key)
  # are substituted at activation from sops, never stored in the Nix store (see render script).
  # Combined installer for BOTH harnesses (pi + opencode), one script, one daemon: the daemon
  # offers whichever CLIs it finds on its PATH, so installing both makes the machine pick its
  # harness per agent in the app.
  machineScript = ''
    #!/usr/bin/env bash
    # Paseo installer (pi + opencode harnesses). Generated by modules/services/paseo.nix -
    # do not edit on the target machine. Idempotent: safe to re-run; it re-creates the same
    # config files and restarts the daemon.
    set -uo pipefail

    PASEO_RELAY_ENDPOINT="${relayPublicHost}"
    # Model traffic goes to the hub's own LiteLLM gateway, on the same Funnel origin this script
    # was downloaded from: an installed machine has no Tailscale, so https://litellm.hp would not
    # even resolve for it. The key below is a LiteLLM key, which is what authorizes and meters
    # every request - and $MODEL_ID names a deployment *in LiteLLM's config*, so pointing these
    # machines at a different model is a gateway change, not a re-install.
    MODEL_BASE_URL="${cfg.model.baseUrl}"
    MODEL_ID="${cfg.model.id}"
    MODEL_KEY='$PASEO_ENROLLMENT_API_KEY'
    INSTALL_TOKEN='$PASEO_ENROLLMENT_TOKEN'

    log() { printf '\033[1;36m[paseo-install]\033[0m %s\n' "$*"; }
    die() { printf '\033[1;31m[paseo-install]\033[0m %s\n' "$*" >&2; exit 1; }

    OS="$(uname -s)"
    ARCH="$(uname -m)"
    NEED_SUDO=""
    if [ "$OS" = "Linux" ] && [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
      NEED_SUDO="sudo"
    fi

    # --- 1. Node.js LTS (>= 22.19, required by the pi/opencode CLIs) ----------------------------
    node_ok() {
      command -v node >/dev/null 2>&1 || return 1
      node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)'
    }

    install_node() {
      log "Installing Node.js 22 LTS..."
      if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        brew install node@22 >/dev/null 2>&1 || brew install node
        eval "$(brew shellenv 2>/dev/null)" || true
      elif command -v apt-get >/dev/null 2>&1 && [ -n "$NEED_SUDO" -o "$(id -u)" = "0" ]; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | ''${NEED_SUDO:+$NEED_SUDO -E} bash - >/dev/null || true
        $NEED_SUDO apt-get install -y nodejs >/dev/null || true
      elif command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | ''${NEED_SUDO:+$NEED_SUDO -E} bash - >/dev/null || true
        $NEED_SUDO dnf install -y nodejs >/dev/null || true
      elif command -v pacman >/dev/null 2>&1; then
        $NEED_SUDO pacman -Sy --noconfirm nodejs npm >/dev/null
      elif command -v apk >/dev/null 2>&1; then
        $NEED_SUDO apk add --no-cache nodejs npm >/dev/null
      fi
      node_ok && return 0

      # Last resort: official static tarball into ~/.local (no root needed).
      log "Falling back to the official Node.js tarball (~/.local/node)."
      case "$ARCH" in
        x86_64) NARCH=x64 ;;
        aarch64 | arm64) NARCH=arm64 ;;
        *) die "unsupported architecture: $ARCH" ;;
      esac
      NV=22.23.3
      # .tar.gz everywhere: slim containers may lack xz for the .xz form.
      if [ "$OS" = "Darwin" ]; then
        NPKG="node-v$NV-darwin-$NARCH.tar.gz"
      else
        NPKG="node-v$NV-linux-$NARCH.tar.gz"
      fi
      mkdir -p "$HOME/.local"
      if curl -fsSL "https://nodejs.org/dist/v$NV/$NPKG" -o /tmp/node-paseo-dl; then
        tar -C "$HOME/.local" -xzf /tmp/node-paseo-dl
        rm -f /tmp/node-paseo-dl
        rm -rf "$HOME/.local/node"
        mv "$HOME/.local"/node-v"$NV"-* "$HOME/.local/node"
      fi
      PATH="$HOME/.local/node/bin:$PATH"; export PATH
      node_ok || die "could not install a Node.js >= 22.19"
    }

    node_ok || install_node
    node_ok || die "Node.js >= 22.19 not available after install (open a new shell and re-run)"
    log "node $(node --version), npm $(npm --version)"

    # --- 2. npm globals (into ~/.npm-global when the system prefix isn't writable) -------------
    NPM_PREFIX="$(npm prefix -g)"
    if ! [ -w "$NPM_PREFIX/lib/node_modules" ] 2>/dev/null && ! [ -w "$NPM_PREFIX" ] 2>/dev/null; then
      NPM_PREFIX="$HOME/.npm-global"
      mkdir -p "$NPM_PREFIX"
      npm config set prefix "$NPM_PREFIX"
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        grep -q 'npm-global/bin' "$rc" 2>/dev/null || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >>"$rc"
      done
    fi
    export PATH="$NPM_PREFIX/bin:$PATH"

    log "Installing @getpaseo/cli + the pi and opencode CLIs (skips when versions match)..."
    # npm >= 11 silently skips install scripts unless allowlisted; @getpaseo/cli needs its
    # node-pty/esbuild builds and the harness CLIs need their postinstall binary downloads.
    as_flag() { npm help install 2>/dev/null | grep -q -- '--allow-scripts' && printf -- '--allow-scripts=%s' "$1"; }
    npm install -g $(as_flag "esbuild,node-pty,msgpackr-extract") @getpaseo/cli@0.11.4 >/dev/null || die "npm install @getpaseo/cli failed"
    npm ls -g @earendil-works/pi-coding-agent --depth=0 2>/dev/null | grep -q pi-coding-agent \
      || npm install -g --ignore-scripts @earendil-works/pi-coding-agent >/dev/null \
      || die "npm install @earendil-works/pi-coding-agent failed"
    npm ls -g opencode-ai --depth=0 2>/dev/null | grep -q opencode-ai \
      || npm install -g $(as_flag "opencode-ai") opencode-ai >/dev/null \
      || die "npm install opencode-ai failed"

    # --- 3. Point BOTH harness CLIs at the hub's LiteLLM gateway ----------------------------------
    log "Configuring pi + opencode for $MODEL_BASE_URL ($MODEL_ID)..."
    ${piConfig}

    ${opencodeConfig}

    # --- 4. Paseo daemon: relay, password, persistence -----------------------------------------
    PASEO_HOME="$HOME/.paseo"
    mkdir -p "$PASEO_HOME"
    chmod 700 "$PASEO_HOME"

    PW_FILE="$PASEO_HOME/daemon-password"
    if [ ! -s "$PW_FILE" ]; then
      if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24 >"$PW_FILE"
      else
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n' >"$PW_FILE"
      fi
      chmod 600 "$PW_FILE"
    fi
    DAEMON_PASSWORD="$(cat "$PW_FILE")"

    cat >"$PASEO_HOME/config.json" <<EOF
    {
      "version": 1,
      "daemon": {
        "listen": "127.0.0.1:6767",
        "relay": {
          "enabled": true,
          "endpoint": "$PASEO_RELAY_ENDPOINT",
          "publicEndpoint": "$PASEO_RELAY_ENDPOINT",
          "useTls": true,
          "publicUseTls": true
        }
      }
    }
    EOF
    chmod 600 "$PASEO_HOME/config.json"

    cat >"$PASEO_HOME/env" <<EOF
    PASEO_HOME=$PASEO_HOME
    PASEO_PASSWORD=$DAEMON_PASSWORD
    PASEO_RELAY_ENABLED=true
    PASEO_RELAY_ENDPOINT=$PASEO_RELAY_ENDPOINT
    PASEO_RELAY_PUBLIC_ENDPOINT=$PASEO_RELAY_ENDPOINT
    PASEO_RELAY_USE_TLS=true
    PASEO_RELAY_PUBLIC_USE_TLS=true
    # NOTE: systemd EnvironmentFile does NOT do shell expansion - the PATH below is baked in
    # with real paths at install time, otherwise node lookups die with status 127.
    PATH=$NPM_PREFIX/bin:$HOME/.local/node/bin:$PATH:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin
    EOF
    chmod 600 "$PASEO_HOME/env"

    stop_any_daemon() {
      # Graceful CLI stop first, then sweep the process family. The old 'bin/paseo daemon run'
      # pattern matched nothing once setproctitle renames the processes ("Paseo Daemon"), so a
      # re-run could leave the old daemon holding :6767 and the health gate would test IT.
      PASEO_HOME="$PASEO_HOME" "$NPM_PREFIX/bin/paseo" daemon stop >/dev/null 2>&1 || true
      pkill -u "$(id -u)" -f 'bin/paseo daemon run' 2>/dev/null || true
      # -f, not -x: the supervisor's title is 16 chars and comm (what -x matches) is
      # truncated to 15, so 'Paseo Supervisor' can never match exactly.
      pkill -u "$(id -u)" -f '^Paseo Supervisor' 2>/dev/null || true
      pkill -u "$(id -u)" -f '^Paseo Daemon' 2>/dev/null || true
      sleep 1
    }

    # systemd detection - the condition must be "systemd is the live init AND a user
    # manager is reachable", never the systemctl exit code alone: devcontainer images
    # ship a /usr/bin/systemctl SHIM that prints "'systemd' is not running in this
    # container due to its overhead. Use the 'service' command instead." and STILL
    # EXITS 0. The old check took the shim's word for it, "installed" a user unit
    # into a filesystem nothing reads, the daemon never started, and the installer
    # hung at "Waiting for the daemon...". /run/systemd/system only exists when
    # systemd really is PID 1; no shim can fake that.
    HAVE_SYSTEMD_USER=""
    if [ "$OS" = "Linux" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      # Belt and braces: if the binary reports systemd is not running, believe the output.
      SM_PROBE="$(systemctl --user show-environment 2>&1)" || SM_PROBE=""
      case "$SM_PROBE" in
        *"not running in this container"*|*"System has not been booted with systemd"*) SM_PROBE="" ;;
      esac
      [ -n "$SM_PROBE" ] && HAVE_SYSTEMD_USER=1
    fi

    STARTED=""
    if [ -n "$HAVE_SYSTEMD_USER" ]; then
      log "Installing systemd user service paseo.service..."
      mkdir -p "$HOME/.config/systemd/user"
      cat >"$HOME/.config/systemd/user/paseo.service" <<EOF
    [Unit]
    Description=Paseo daemon (pi + opencode machine)
    After=network-online.target

    [Service]
    EnvironmentFile=$PASEO_HOME/env
    ExecStart=$NPM_PREFIX/bin/paseo daemon run
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=default.target
    EOF
      systemctl --user daemon-reload
      systemctl --user restart paseo.service
      systemctl --user enable paseo.service >/dev/null 2>&1 || true
      command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
      STARTED=systemd
    elif [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
      log "Installing launchd agent sh.paseo.daemon..."
      mkdir -p "$HOME/Library/LaunchAgents"
      cat >"$HOME/Library/LaunchAgents/sh.paseo.daemon.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>sh.paseo.daemon</string>
      <key>ProgramArguments</key><array>
        <string>$NPM_PREFIX/bin/paseo</string><string>daemon</string><string>run</string>
      </array>
      <key>EnvironmentVariables</key><dict>
        <key>PASEO_HOME</key><string>$PASEO_HOME</string>
        <key>PASEO_PASSWORD</key><string>$DAEMON_PASSWORD</string>
        <key>PASEO_RELAY_ENABLED</key><string>true</string>
        <key>PASEO_RELAY_ENDPOINT</key><string>$PASEO_RELAY_ENDPOINT</string>
        <key>PASEO_RELAY_PUBLIC_ENDPOINT</key><string>$PASEO_RELAY_ENDPOINT</string>
        <key>PASEO_RELAY_USE_TLS</key><string>true</string>
        <key>PASEO_RELAY_PUBLIC_USE_TLS</key><string>true</string>
        <key>PATH</key><string>$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin</string>
      </dict>
      <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>$PASEO_HOME/launchd.out</string>
      <key>StandardErrorPath</key><string>$PASEO_HOME/launchd.err</string>
    </dict></plist>
    EOF
      launchctl bootout "gui/$(id -u)/sh.paseo.daemon" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/sh.paseo.daemon.plist" >/dev/null 2>&1 || true
      STARTED=launchd
    fi

    if [ -z "$STARTED" ]; then
      # No usable service manager (containers without systemd, SLURM nodes, plain ssh
      # sessions etc.): background the daemon so this machine still pairs. Re-running
      # this script is the "supervisor" after a container restart; for real supervision
      # add your own (s6, runit, docker-init, the SLURM deployer, or a systemd unit
      # once a user manager exists).
      log "No systemd/launchd detected - starting the daemon in the background (nohup)."
      log "  It will NOT survive a container restart: re-run this command, or run"
      log "  'paseo daemon run' in the foreground yourself to keep it in the terminal."
      stop_any_daemon
      ( set -a; . "$PASEO_HOME/env"; set +a
        setsid nohup "$NPM_PREFIX/bin/paseo" daemon run >>"$PASEO_HOME/daemon.out" 2>&1 & )
      STARTED=nohup
    fi

    log "Waiting for the daemon..."
    for _ in $(seq 1 30); do
      curl -sf http://127.0.0.1:6767/api/health >/dev/null 2>&1 && break
      sleep 1
    done
    if ! curl -sf http://127.0.0.1:6767/api/health >/dev/null 2>&1; then
      [ "$STARTED" = nohup ] && tail -n 15 "$PASEO_HOME/daemon.out" >&2 2>/dev/null || true
      [ "$STARTED" = systemd ] && systemctl --user status paseo.service --no-pager -n 15 >&2 2>/dev/null || true
      die "daemon did not come up (started via $STARTED; see $PASEO_HOME/daemon.log and $PASEO_HOME/daemon.out)"
    fi

    # --- 5. Pairing link ------------------------------------------------------------------------
    # /api/health answers before the WS layer finishes warming (early attempts 503) - retry.
    PAIR_URL=""
    for _ in $(seq 1 15); do
      PAIR_JSON="$(PASEO_HOME="$PASEO_HOME" PASEO_PASSWORD="$DAEMON_PASSWORD" \
        "$NPM_PREFIX/bin/paseo" --host "tcp://127.0.0.1:6767?password=$DAEMON_PASSWORD" daemon pair --json 2>/dev/null)"
      PAIR_URL="$(printf '%s' "$PAIR_JSON" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).url||"")}catch{console.log("")}})')"
      [ -n "$PAIR_URL" ] && break
      sleep 2
    done

    # Hand the link to hp's cockpit (token-gated); it shows up there as a one-click
    # "add to hub" entry. Best-effort: offline machines just skip this.
    if [ -n "$PAIR_URL" ]; then
      MNAME="$(hostname 2>/dev/null || uname -n)"
      MNAME="$(printf '%s' "$MNAME" | tr -c 'A-Za-z0-9._-' '-')"
      # Full host profile -> the sync directory -> every dashboard (no click needed).
      PROFILE="$(PAIR_URL="$PAIR_URL" DAEMON_PASSWORD="$DAEMON_PASSWORD" MNAME="$MNAME" node -e 'const o=JSON.parse(Buffer.from((process.env.PAIR_URL.split("#offer=")[1]||"").replace(/-/g,"+").replace(/_/g,"/"),"base64").toString());process.stdout.write(JSON.stringify({serverId:o.serverId,label:process.env.MNAME,password:process.env.DAEMON_PASSWORD,connections:[{type:"relay",relayEndpoint:o.relay.endpoint,useTls:o.relay.useTls!==false,daemonPublicKeyB64:o.daemonPublicKeyB64}],createdAt:new Date().toISOString()}))' 2>/dev/null || true)"
      EXTRA="$( [ -n "$PROFILE" ] && printf ',"profile":%s' "$PROFILE" )"
      REG_BODY="$(printf '{"token":"%s","name":"%s","url":"%s"%s}' "$INSTALL_TOKEN" "$MNAME" "$PAIR_URL" "$EXTRA")"
      if curl -fsS -m 15 -X POST -H 'content-type: application/json' --data "$REG_BODY" \
        "https://hp.tail546fb.ts.net:8443/paseo-api/register" >/dev/null 2>&1; then
        log "Registered on the cockpit. It also joins every dashboard automatically now"
        log "(shared host sync on paseo.hp - just reload the page there)."
      else
        log "(could not register on the cockpit - pair manually with the link below)"
      fi
    fi

    echo
    log "Done. pi + opencode machine is up and talking to the relay via $PASEO_RELAY_ENDPOINT."
    log "Add it to the Paseo app on your phone/laptop with this pairing link:"
    echo "      ''${PAIR_URL:-<could not generate - run: paseo daemon pair --json>}"
    echo
    log "Daemon password: $DAEMON_PASSWORD (also in $PW_FILE)"
    log "Model: $MODEL_ID via $MODEL_BASE_URL"
    log "  pi:       pi --model ${cfg.model.provider}/$MODEL_ID -p \"...\""
    log "  opencode: opencode run -m ${cfg.model.provider}/$MODEL_ID \"...\""
  '';

  # opencode.json: custom OpenAI-compatible provider (opencode.ai/docs/providers), model
  # reference <providerId>/<modelKey>.
  opencodeConfig = ''
    mkdir -p "$HOME/.config/opencode"
    cat >"$HOME/.config/opencode/opencode.json" <<EOF
    {
      "\$schema": "https://opencode.ai/config.json",
      "provider": {
        "${cfg.model.provider}": {
          "npm": "@ai-sdk/openai-compatible",
          "name": "${cfg.model.providerLabel}",
          "options": { "baseURL": "$MODEL_BASE_URL", "apiKey": "$MODEL_KEY" },
          "models": { "$MODEL_ID": ${ocModelJson} }
        }
      },
      "model": "${cfg.model.provider}/$MODEL_ID"
    }
    EOF
    chmod 600 "$HOME/.config/opencode/opencode.json"
  '';

  # pi models.json (~/.pi/agent/models.json): compatible OpenAI endpoint
  # (badlogic/pi-mono packages/coding-agent/docs/models.md).
  piConfig = ''
    mkdir -p "$HOME/.pi/agent"
    cat >"$HOME/.pi/agent/models.json" <<EOF
    {
      "\$schema": "https://pi.dev/schemas/models.schema.json",
      "providers": {
        "${cfg.model.provider}": {
          "baseUrl": "$MODEL_BASE_URL",
          "api": "openai-completions",
          "apiKey": "$MODEL_KEY",
          "models": [ ${piModelJson} ]
        }
      }
    }
    EOF
    chmod 600 "$HOME/.pi/agent/models.json"
    ${lib.optionalString hasModelThinking ''
      # pi's startup thinking level, per model: settings.json's modelThinkingLevels is keyed by
      # "<provider>/<modelId>", so this sets a default for THIS model and says nothing about any
      # other pi might drive. pi owns and writes this file too (theme, changelog seen, levels saved
      # with Ctrl+S), so merge our one key instead of replacing it - node is on PATH by now (step 1),
      # and an unparseable file is set aside rather than eaten.
      cat >"$HOME/.pi/agent/.paseo-settings.json" <<EOF
      { "modelThinkingLevels": { "${cfg.model.provider}/$MODEL_ID": "${cfg.model.thinkingDefault}" } }
      EOF
      node -e '
        const fs = require("fs");
        const [target, add] = process.argv.slice(1);
        let cur = {};
        if (fs.existsSync(target)) {
          try { cur = JSON.parse(fs.readFileSync(target, "utf8")); }
          catch (e) { fs.copyFileSync(target, target + ".paseo-backup"); }
        }
        const want = JSON.parse(fs.readFileSync(add, "utf8"));
        cur.modelThinkingLevels = Object.assign({}, cur.modelThinkingLevels, want.modelThinkingLevels);
        fs.writeFileSync(target, JSON.stringify(cur, null, 2) + "\n");
      ' "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/.paseo-settings.json" \
        && rm -f "$HOME/.pi/agent/.paseo-settings.json" \
        || log "could not set the default thinking level in ~/.pi/agent/settings.json (pi still offers /thinking)"
    ''}
  '';

  # SLURM deployer: submits machine.sh as a long allocation so a cluster can host the machine.
  # Defaults (overridable via env): 2 CPUs, 5120 MB RAM, NO GPUs, infinite walltime. The job
  # script itself is the daemon supervisor (installer runs inside the job, then the job execs
  # `paseo daemon run`), so scancel stops the machine and re-submitting re-starts it - the
  # machine identity (keypair in ~/.paseo) survives, each submit just mints a fresh single-use
  # pairing link that lands in the waiting list below.
  slurmScript = ''
    #!/usr/bin/env bash
    # Paseo SLURM deployer. Generated by modules/services/paseo.nix - do not edit on the target
    # machine. Run on a login node: sbatch-wraps the pi+opencode installer.
    # Knobs via env: CPUS MEM_MB TIME PARTITION GRES JOB_NAME PASEO_INSTALL_URL, e.g.
    #   curl -fsSL https://hp.tail546fb.ts.net:8443/install/<token>/slurm.sh -o slurm.sh
    #   CPUS=4 MEM_MB=8192 GRES=gpu:1 PARTITION=gpu bash slurm.sh
    set -uo pipefail

    log() { printf '\033[1;36m[paseo-slurm]\033[0m %s\n' "$*"; }
    die() { printf '\033[1;31m[paseo-slurm]\033[0m %s\n' "$*" >&2; exit 1; }

    CPUS="''${CPUS:-2}"
    MEM_MB="''${MEM_MB:-5120}"
    TIME="''${TIME:-infinite}"
    JOB_NAME="''${JOB_NAME:-paseo-machine}"
    PARTITION="''${PARTITION:-}"
    GRES="''${GRES:-}"
    INSTALL_URL="''${PASEO_INSTALL_URL:-https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/machine.sh}"

    command -v sbatch >/dev/null 2>&1 || die "sbatch not found - run this on a SLURM login node"

    JOB="$(mktemp "''${TMPDIR:-/tmp}/paseo-machine-job.XXXXXX")"
    trap 'rm -f "$JOB"' EXIT

    cat >"$JOB" <<EOF
    #!/usr/bin/env bash
    #SBATCH --job-name=$JOB_NAME
    #SBATCH --cpus-per-task=$CPUS
    #SBATCH --mem=''${MEM_MB}M
    #SBATCH --time=$TIME
    #SBATCH --output=$JOB_NAME-%j.out
    # No --gres by default: the machine requests no GPUs (set GRES=gpu:1 to change that).
    set -uo pipefail

    echo "[paseo-slurm] job \$SLURM_JOB_ID on \$(hostname): installing the pi + opencode machine"
    curl -fsSL '$INSTALL_URL' | bash \
      || { echo "[paseo-slurm] installer failed - see this job's log" >&2; exit 1; }

    # The installer starts the daemon from a non-login shell (nohup fallback on slurm nodes,
    # which usually have no user systemd); take it over so the allocation supervises it.
    pkill -u "\$(id -u)" -f 'bin/paseo daemon run' 2>/dev/null || true
    sleep 1
    set -a; . "\$HOME/.paseo/env"; set +a
    cd "\$HOME" || exit 1
    exec paseo daemon run
    EOF
    # The job file embeds the enrollment token inside INSTALL_URL.
    chmod 600 "$JOB"

    log "submitting: cpus=$CPUS mem=''${MEM_MB}M time=$TIME gres=''${GRES:-none} partition=''${PARTITION:-<cluster default>}"
    sbatch \
      ''${PARTITION:+--partition="$PARTITION"} \
      ''${GRES:+--gres="$GRES"} \
      "$JOB" \
      || die "sbatch failed"
    log "job submitted - the machine lives as long as the allocation does."
    log "Its pairing link shows up below once the job's installer step finishes; stop it with:"
    log "  scancel \"$JOB_NAME\""
  '';

  # Uninstaller: the exact inverse of machine.sh - stops the daemon + its service unit, removes
  # the paseo/pi/opencode npm CLIs and ALL of their config, credentials and data under $HOME.
  # Refuses on hosts where the machine is NixOS-declarative (MODULES.services.paseo-machine owns
  # those paths and the service would just regenerate them) unless PASEO_UNINSTALL_FORCE=1.
  uninstallScript = ''
    #!/usr/bin/env bash
    # Paseo uninstaller. Generated by modules/services/paseo.nix - do not edit on the target
    # machine. Removes everything machine.sh installed: the daemon service, the paseo + pi +
    # opencode CLIs, the Node tarball fallback, and ALL config/credentials/data under $HOME.
    # Idempotent: missing paths are skipped, never fatal.
    set -uo pipefail

    log() { printf '\033[1;36m[paseo-uninstall]\033[0m %s\n' "$*"; }
    die() { printf '\033[1;31m[paseo-uninstall]\033[0m %s\n' "$*" >&2; exit 1; }

    OS="$(uname -s)"

    # A NixOS-declarative machine (paseo-machine-<user>.service) belongs to the NixOS config:
    # wiping its state while the unit runs only lets ExecStartPre regenerate everything.
    UNIT="/etc/systemd/system/paseo-machine-$(id -un).service"
    if [ -f "$UNIT" ] && [ "''${PASEO_UNINSTALL_FORCE:-}" != "1" ]; then
      die "$UNIT exists - this machine is declared in NixOS (MODULES.services.paseo-machine):
    remove the entry from the host config and rebuild. Re-run with PASEO_UNINSTALL_FORCE=1
    to remove this user's state anyway."
    fi

    # --- 1. stop + remove the service the installer installed -------------------------------------
    # Kill the daemon FIRST, regardless of supervisor: on container images whose
    # systemctl is a non-functional shim, 'systemctl disable --now' below "succeeds"
    # while the nohup'd daemon keeps running off files we are about to delete.
    if pgrep -u "$(id -u)" -f 'bin/paseo daemon run' >/dev/null 2>&1 \
       || pgrep -u "$(id -u)" -f '^Paseo Daemon' >/dev/null 2>&1 \
       || pgrep -u "$(id -u)" -f '^Paseo Supervisor' >/dev/null 2>&1; then
      log "killing a running paseo daemon (nohup/manual start)"
      pkill -u "$(id -u)" -f 'bin/paseo daemon run' 2>/dev/null || true
      pkill -u "$(id -u)" -f '^Paseo Supervisor' 2>/dev/null || true
      pkill -u "$(id -u)" -f '^Paseo Daemon' 2>/dev/null || true
      sleep 1
    fi
    if [ "$OS" = "Linux" ] && [ -f "$HOME/.config/systemd/user/paseo.service" ] && command -v systemctl >/dev/null 2>&1; then
      log "disabling + removing the installer's systemd user unit"
      systemctl --user disable --now paseo.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/paseo.service" \
            "$HOME/.config/systemd/user/default.target.wants/paseo.service"
      systemctl --user daemon-reload 2>/dev/null || true
      systemctl --user reset-failed paseo.service 2>/dev/null || true
    fi
    if [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
      log "removing the launchd agent sh.paseo.daemon"
      launchctl bootout "gui/$(id -u)/sh.paseo.daemon" >/dev/null 2>&1 || true
      rm -f "$HOME/Library/LaunchAgents/sh.paseo.daemon.plist"
    fi
    # nohup fallback (containers, SLURM compute nodes) or a manually started daemon.
    if pgrep -u "$(id -u)" -f 'bin/paseo daemon run' >/dev/null 2>&1; then
      log "killing a running 'paseo daemon run'"
      pkill -u "$(id -u)" -f 'bin/paseo daemon run' 2>/dev/null || true
    fi

    # --- 2. the npm globals (in whatever prefix npm resolves today) --------------------------------
    if command -v npm >/dev/null 2>&1; then
      log "removing the npm globals: paseo CLI + pi + opencode"
      npm uninstall -g @getpaseo/cli @earendil-works/pi-coding-agent opencode-ai >/dev/null 2>&1 || true
    fi

    # --- 3. every path the installer or the CLIs ever touched --------------------------------------
    remove() { [ -e "$1" ] || return 0; log "removing $1"; rm -rf -- "$1"; }

    remove "$HOME/.paseo"             # config, env, keypair (identity), logs, daemon password
    remove "$HOME/.config/paseo"      # credentials dir (installer + service layout)
    remove "$HOME/.local/share/paseo"
    remove "$HOME/.local/state/paseo"
    remove "$HOME/.cache/paseo"
    remove "$HOME/.pi"                # pi config/auth/sessions
    remove "$HOME/.config/pi"
    remove "$HOME/.local/share/pi"
    remove "$HOME/.cache/pi"
    remove "$HOME/.config/opencode"   # opencode config/auth
    remove "$HOME/.local/share/opencode"
    remove "$HOME/.local/state/opencode"
    remove "$HOME/.cache/opencode"
    remove "$HOME/.npm-global"        # installer's npm prefix (bin shims included)
    remove "$HOME/.local/node"        # Node tarball fallback

    # Installer's npm prefix line in ~/.npmrc (drop the file if that was all it held).
    if [ -f "$HOME/.npmrc" ] && grep -q "$HOME/.npm-global" "$HOME/.npmrc" 2>/dev/null; then
      grep -v "$HOME/.npm-global" "$HOME/.npmrc" >"$HOME/.npmrc.tmp" 2>/dev/null || true
      if [ -s "$HOME/.npmrc.tmp" ]; then
        log "stripping the installer's npm prefix from ~/.npmrc"
        mv "$HOME/.npmrc.tmp" "$HOME/.npmrc"
      else
        log "removing ~/.npmrc (it only held the installer's npm prefix)"
        rm -f "$HOME/.npmrc.tmp" "$HOME/.npmrc"
      fi
    fi

    # rc-file PATH lines the installer appended (a .bak copy is kept on first removal).
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      if [ -f "$rc" ] && grep -q 'npm-global/bin\|\.local/node/bin' "$rc" 2>/dev/null; then
        log "dropping installer PATH lines from $rc"
        sed -i.bak '/npm-global\/bin/d; /\.local\/node\/bin/d' "$rc"
      fi
    done

    # Node from a package manager / brew (installer section 1) stays - other tools may use it.
    log "done. Open a new shell (or source ~/.zshrc) to drop the stale PATH."
    log "The machine goes offline on the hub; delete its stale cockpit entry with the trash button."
  '';

  # SLURM uninstaller: cancels the machine's jobs by name from the login node, then submits a
  # tiny one-shot job that runs the uninstaller against $HOME - slurm.sh already assumes the
  # compute nodes share the home filesystem, so this reaches the same install.
  slurmUninstallScript = ''
    #!/usr/bin/env bash
    # Paseo SLURM uninstaller. Generated by modules/services/paseo.nix - do not edit on the
    # target machine. Run on a login node: scancels the machine's jobs, then sbatches a one-shot
    # cleanup job (1 CPU, 512 MB, 10 min, no GPUs) that removes the install + ALL config/data
    # from $HOME. Knobs via env: PARTITION JOB_NAME PASEO_UNINSTALL_URL PASEO_UNINSTALL_FORCE.
    set -uo pipefail

    log() { printf '\033[1;36m[paseo-slurm]\033[0m %s\n' "$*"; }
    die() { printf '\033[1;31m[paseo-slurm]\033[0m %s\n' "$*" >&2; exit 1; }

    JOB_NAME="''${JOB_NAME:-paseo-machine}"
    PARTITION="''${PARTITION:-}"
    FORCE="''${PASEO_UNINSTALL_FORCE:-}"
    UNINSTALL_URL="''${PASEO_UNINSTALL_URL:-https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/uninstall.sh}"

    command -v sbatch >/dev/null 2>&1 || die "sbatch not found - run this on a SLURM login node"

    # Stop the machine first: a daemon still running while the cleanup job deletes its files
    # would just write them back. scancel without -u only touches THIS user's jobs.
    if command -v scancel >/dev/null 2>&1; then
      log "cancelling running/pending jobs named '$JOB_NAME'"
      scancel -n "$JOB_NAME" 2>/dev/null || true
    fi

    JOB="$(mktemp "''${TMPDIR:-/tmp}/paseo-uninstall-job.XXXXXX")"
    trap 'rm -f "$JOB"' EXIT

    cat >"$JOB" <<EOF
    #!/usr/bin/env bash
    #SBATCH --job-name=paseo-uninstall
    #SBATCH --cpus-per-task=1
    #SBATCH --mem=512M
    #SBATCH --time=00:10:00
    #SBATCH --output=paseo-uninstall-%j.out
    # No --gres: cleanup never needs GPUs.
    set -uo pipefail

    echo "[paseo-slurm] job \$SLURM_JOB_ID on \$(hostname): removing the paseo machine + all config"
    curl -fsSL '$UNINSTALL_URL' | PASEO_UNINSTALL_FORCE=$FORCE bash \
      || { echo "[paseo-slurm] uninstaller failed - see this job's log" >&2; exit 1; }
    EOF
    # The job file embeds the enrollment token inside UNINSTALL_URL.
    chmod 600 "$JOB"

    log "submitting cleanup job partition=''${PARTITION:-<cluster default>}"
    sbatch \
      ''${PARTITION:+--partition="$PARTITION"} \
      "$JOB" \
      || die "sbatch failed"
    log "cleanup job submitted - watch it with: squeue -n paseo-uninstall"
  '';

  # Templates for the activation-time renderer; secret placeholders ($PASEO_...) are plain
  # literals here - envsubst substitutes them from sops, so nothing secret lands in the store.
  # The renderer serves each as <name>.sh under /install/<token>/ (basename minus the store
  # hash prefix and the .tmpl suffix).
  machineScriptTmpl = pkgs.writeText "machine.tmpl" machineScript;
  slurmScriptTmpl = pkgs.writeText "slurm.tmpl" slurmScript;
  uninstallScriptTmpl = pkgs.writeText "uninstall.tmpl" uninstallScript;
  slurmUninstallScriptTmpl = pkgs.writeText "slurm-uninstall.tmpl" slurmUninstallScript;

  cockpit = pkgs.writeText "cockpit.html" ''
    <!doctype html>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Paseo cockpit</title>
    <link rel="icon" href="favicon.ico">
    <style>
      body{font-family:system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;background:#101418;color:#dde}
      h1{font-size:1.4rem} h2{font-size:1.05rem;margin-top:2rem}
      a{color:#7cc4ff}
      pre{background:#1c222a;padding:.7rem;padding-top:1.9rem;border-radius:6px;overflow-x:auto;font-size:.85rem;position:relative}
      .note{font-size:.85rem;color:#9ab}
      code{background:#1c222a;padding:.1rem .3rem;border-radius:3px}
      button.copy{position:absolute;top:.3rem;right:.3rem;background:#2a3340;color:#bcd;border:1px solid #3a4655;border-radius:4px;font-size:.72rem;padding:.15rem .5rem;cursor:pointer}
      button.copy:hover{background:#33404f}
      button.copy.done{color:#8f8;border-color:#465}
      .machines .entry{border:1px solid #2a3340;border-radius:6px;padding:.6rem .8rem;margin:.6rem 0;background:#161c22}
      .machines a.add{display:inline-block;background:#274b6d;color:#dfe;padding:.3rem .7rem;border-radius:5px;text-decoration:none;font-size:.85rem}
      button.del{background:none;border:1px solid #543;color:#c99;border-radius:5px;font-size:.75rem;padding:.25rem .55rem;margin-left:.6rem;cursor:pointer}
      .empty{color:#9ab;font-size:.85rem}
    </style>
    <h1>Paseo cockpit <span class="note">(tailnet only)</span></h1>

    <h2>Dashboard</h2>
    <p><a href="https://paseo.hp/">https://paseo.hp/</a> - or <a href="/paseo">/paseo</a> on this funnel origin.</p>
    <p class="note">Hosts are shared between your dashboards now (storage sync, see below): add a host once on any
    device and it appears on every device after a page reload. The sync only covers browsers that have loaded this
    dashboard at least once while on the tailnet.</p>
    <p>Daemon password (enter when the dashboard asks):</p>
    <pre>$PASEO_DAEMON_PASSWORD</pre>

    <h2>Hub pairing link (phone/laptop &rarr; "paste pairing link")</h2>
    <pre>$PASEO_PAIRING_URL</pre>
    <p>
      <button id="remint" type="button" class="del">Mint new hub pairing link</button>
      <span class="note" id="remintmsg">Each link is single-use. On a new device, mint a fresh one and paste it -
      already-added devices keep working (the link was just delivery).</span>
    </p>

    ${lib.optionalString config.MODULES.services.paseo-hermes.enable ''
      <h2>Hermes machine pairing link (phone/laptop &rarr; "paste pairing link")</h2>
      <p class="note">Second Paseo daemon on this host, running as the Hermes user: loopback-only, ACP provider
      "Hermes", dials out to the relay like any harness machine. Already seeded into the shared host sync as
      <code>hermes-hp</code>, so it appears in every dashboard after a reload - the single-use link below is only
      for a device that never loaded a synced dashboard. Re-mint (as root):
      <code>rm /var/lib/paseo-web/hermes-pairing-url &amp;&amp; systemctl restart paseo-hermes-pair</code>.</p>
      $PASEO_HERMES_PAIRING_HTML
    ''}
    <h2>Add a harness machine</h2>
    <p class="note">Run on any Linux/macOS box (no Tailscale needed - it reaches the hub through the public relay):
    installs Node + <code>@getpaseo/cli</code> + <strong>both</strong> harness CLIs (pi and opencode, the daemon offers
    either per agent), points them at the hub's LiteLLM gateway, registers the machine with the
    relay, and posts its pairing link back here. Re-runnable.</p>
    <h3>Direct (any box)</h3>
    <pre>curl -fsSL https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/machine.sh | bash</pre>
    <h3>As a SLURM job (cluster)</h3>
    <p class="note">Submitted with <code>sbatch</code> from a login node: <strong>2 CPUs, 5 GB RAM, no GPUs, infinite
    walltime</strong> by default - the job supervises the daemon, so <code>scancel paseo-machine</code> stops the
    machine and a re-submit restarts it (same machine identity, fresh pairing link here). Tune per submit:
    <code>CPUS=4 MEM_MB=8192 GRES=gpu:1 PARTITION=gpu bash slurm.sh</code> after saving it with
    <code>-o slurm.sh</code>.</p>
    <pre>curl -fsSL https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/slurm.sh | bash</pre>

    <h3>Removing it again</h3>
    <p class="note">Stops the daemon and its service, uninstalls the paseo/pi/opencode CLIs and deletes <strong>all</strong>
    their config, credentials and data under <code>$HOME</code> (the machine identity too - it re-pairs as a fresh
    machine if you install again). Refuses on NixOS-declarative machines - remove those from the host config instead.
    The SLURM variant first <code>scancel</code>s the machine's jobs, then runs the cleanup as a one-shot job against
    the shared home.</p>
    <pre>curl -fsSL https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/uninstall.sh | bash</pre>
    <pre>curl -fsSL https://hp.tail546fb.ts.net:8443/install/$PASEO_ENROLLMENT_TOKEN/slurm-uninstall.sh | bash</pre>

    <h2>Waiting machines</h2>
    <p class="note">Links posted by installers, not yet added to a dashboard. <strong>Add to hub</strong> opens the
    hub dashboard with the pairing link pre-consumed (one click, no pasting; works in whichever browser
    you keep the dashboard in - but only the first one: each link is single-use, so re-run the installer command
    above on the machine for a fresh link per extra device). Entries expire after 7 days.</p>
    <div class="machines">$PASEO_MACHINES_HTML</div>

    <h2>What this does / rotating secrets</h2>
    <p class="note">Architecture and rotation: <code>hosts/hp/RUNBOOK/RUNBOOK-paseo.md</code> in this repo.
    Enrollment token = the URL secret above (rotate: <code>sops set sops/secrets.yaml '["paseo"]["enrollment_token"]' ...</code> + rebuild - old URLs 404).
    Model key (<code>${cfg.model.apiKeySecret}</code> in sops - a <strong>LiteLLM</strong> key, since the harnesses these
    scripts write talk to the gateway now, not to the upstream behind it): <code>sops set sops/secrets.yaml ...</code> +
    rebuild - re-rendered scripts pick it up (machines already installed keep the old key in their CLI config). Mint a
    dedicated virtual key on the gateway (dashboard &rarr; API Keys, capped to one model) rather than reusing the master
    key: this value goes to every machine that knows the enrollment URL.</p>

    <script>
    document.querySelectorAll("pre").forEach(function (pre) {
      var text = pre.innerText.trim();
      var btn = document.createElement("button");
      btn.className = "copy";
      btn.type = "button";
      btn.textContent = "copy";
      btn.onclick = function () {
        function done() {
          btn.textContent = "copied!";
          btn.classList.add("done");
          setTimeout(function () { btn.textContent = "copy"; btn.classList.remove("done"); }, 1500);
        }
        function fallback() {
          var ta = document.createElement("textarea");
          ta.value = text;
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand("copy"); done(); } catch (e) {}
          document.body.removeChild(ta);
        }
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(done, fallback);
        } else {
          fallback();
        }
      };
      pre.appendChild(btn);
    });
    </script>
    <script>
    var TOK = "$PASEO_ENROLLMENT_TOKEN";
    document.querySelectorAll("button.del").forEach(function (b) {
      b.onclick = function () {
        fetch("/paseo-api/entry/" + b.getAttribute("data-id"), {
          method: "DELETE",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ token: TOK }),
        }).then(function () { location.reload(); });
      };
    });
    </script>
    <script>
    var remint = document.getElementById("remint");
    if (remint) {
      remint.onclick = function () {
        var msg = document.getElementById("remintmsg");
        remint.disabled = true;
        msg.textContent = "minting...";
        fetch("/paseo-api/remint-hub", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ token: TOK }),
        }).then(function (r) {
          return r.json().then(function (j) { return { r: r, j: j }; });
        }).then(function (res) {
          if (!res.r.ok) {
            msg.textContent = "failed: " + JSON.stringify(res.j);
            remint.disabled = false;
            return;
          }
          msg.textContent = "minted - the cockpit re-renders within ~30s, then copy/paste the new link on the device";
          setTimeout(function () { location.reload(); }, 35000);
        }).catch(function (e) {
          msg.textContent = "failed: " + e;
          remint.disabled = false;
        });
      };
    }
    </script>
  '';

  nginxUrl = "http://127.0.0.1:${toString config.PORTS.paseoWeb}";

  # Root can't help here: ExecStart scripts run under the unit's User=, so the secret files
  # carry that user's group. systemd's EnvironmentFiles= is avoided because a pre-253 PID1
  # (still running right after activation) silently ignores the key.
  relayStart = pkgs.writeShellScriptBin "paseo-relay-start" ''
    set -euo pipefail
    export RELEASE_COOKIE="$(cat ${config.sops.secrets."paseo/relay_release_cookie".path})"
    exec ${paseoRelay}/bin/paseo_relay start
  '';

  daemonStart = pkgs.writeShellScriptBin "paseo-daemon-start" ''
    set -euo pipefail
    export PASEO_PASSWORD="$(cat ${config.sops.secrets."paseo/daemon_password".path})"
    exec ${paseoCli}/bin/paseo daemon run
  '';

  # Tiny token-gated endpoint the installer scripts POST their pairing link to (and the
  # cockpit's delete buttons DELETE from). Loopback only; nginx + the /paseo-api Traefik
  # route expose it. Written files live in the registry dir; a systemd path unit re-renders
  # the cockpit when it changes.
  registryPy = pkgs.writeText "paseo-registry.py" ''
    import json, os, re, subprocess, time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    REG_DIR = os.environ["PASEO_REGISTRY_DIR"]
    TOKEN_FILE = os.environ["PASEO_TOKEN_FILE"]
    PORT = int(os.environ["PASEO_REGISTRY_PORT"])
    CLI = os.environ["PASEO_CLI"]
    DAEMON_URL = os.environ["PASEO_DAEMON_URL"]
    PAIRING_FILE = os.environ["PASEO_PAIRING_FILE"]
    # Cross-device localStorage directory written by the dashboard sync shim and the
    # installers (dotfile: not picked up by the cockpit's *.json machine glob).
    DIRECTORY = os.path.join(REG_DIR, ".directory")
    REGISTRY_KEY = "@paseo:daemon-registry"
    MAX_BODY = 8 * 1024 * 1024


    def token():
        with open(TOKEN_FILE) as f:
            return f.read().strip()


    def load_dir():
        try:
            with open(DIRECTORY) as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}


    def save_dir(d):
        tmp = DIRECTORY + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, DIRECTORY)


    def valid_profile(p):
        return (
            isinstance(p, dict)
            and isinstance(p.get("serverId"), str)
            and p["serverId"]
            and isinstance(p.get("connections"), list)
            and len(p["connections"]) > 0
        )


    def upsert_profile(d, prof):
        """Add/replace one host entry in the synced registry array (union by serverId, so
        installer-injected entries are never lost when a device pushes its own array)."""
        cur = []
        try:
            cur = json.loads(d.get(REGISTRY_KEY, {}).get("v", "[]"))
        except Exception:
            cur = []
        if not isinstance(cur, list):
            cur = []
        by = {}
        for h in cur + [prof]:
            if isinstance(h, dict) and isinstance(h.get("serverId"), str) and h["serverId"]:
                by[h["serverId"]] = h
        arr = list(by.values())
        ent = d.get(REGISTRY_KEY)
        ts = ent.get("ts", 0) if isinstance(ent, dict) else 0
        d[REGISTRY_KEY] = {"v": json.dumps(arr), "ts": ts}


    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _json_body(self, limit=65536):
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return None
            if n <= 0 or n > limit:
                return None
            try:
                return json.loads(self.rfile.read(n))
            except Exception:
                return None

        def _authorized(self, body):
            return isinstance(body, dict) and body.get("token") == token()

        def _sync_hosts(self):
            # Body: {"kv": {"<localStorage key>": "<value>"|null, ...}, "removed": ["<serverId>"]?}
            # - pushed changed keys from a device's dashboard (null = key deleted).
            # Per-key last-writer-wins, EXCEPT the host registry array, which is union-merged by
            # serverId (device entries win over older server copies) minus any tombstoned
            # serverIds, so an installer entry can't be lost to a stale device push but a host
            # the user deleted stays deleted.
            body = self._json_body(MAX_BODY)
            if not isinstance(body, dict) or not isinstance(body.get("kv"), dict):
                return self._send(400, {"error": "bad body"})
            removed = {r for r in body.get("removed", []) if isinstance(r, str)}
            now = time.time()
            stamps, out = {}, {}
            d = load_dir()
            for k, v in list(body["kv"].items())[:200]:
                if not isinstance(k, str) or not k or len(k) > 200 or k == "@paseo:sync-meta":
                    continue
                if v is None:
                    d.pop(k, None)
                    stamps[k] = now
                    continue
                if not isinstance(v, str) or len(v) > 1024 * 1024:
                    continue
                if k == REGISTRY_KEY:
                    try:
                        new = json.loads(v)
                    except Exception:
                        continue
                    if not isinstance(new, list):
                        continue
                    try:
                        cur = json.loads(d.get(REGISTRY_KEY, {}).get("v", "[]"))
                    except Exception:
                        cur = []
                    if not isinstance(cur, list):
                        cur = []
                    by = {}
                    for h in cur + new:
                        if isinstance(h, dict) and isinstance(h.get("serverId"), str) and h["serverId"]:
                            prev = by.get(h["serverId"])
                            # The app's own stored profile omits the password (it keeps that
                            # elsewhere); a device push must not discard a password the
                            # installer/pair unit provided, or new devices get prompted.
                            if prev and "password" in prev and not h.get("password"):
                                h = {**h, "password": prev["password"]}
                            by[h["serverId"]] = h
                    for sid in removed:
                        by.pop(sid, None)
                    v = json.dumps(list(by.values()))
                d[k] = {"v": v, "ts": now}
                stamps[k] = now
            save_dir(d)
            return self._send(200, {"ok": True, "ts": stamps})

        def _seed_hub(self):
            # paseo-pair.service posts the hub's own profile once (loopback-only endpoint).
            body = self._json_body()
            prof = body.get("profile") if isinstance(body, dict) else None
            if not valid_profile(prof):
                return self._send(400, {"error": "bad profile"})
            d = load_dir()
            upsert_profile(d, prof)
            save_dir(d)
            return self._send(200, {"ok": True})

        def _remint_hub(self):
            # Fresh single-use offer for the local hub daemon; the cockpit re-renders it via
            # its 30s timer (pairing-url is group-writable for this user). The password rides
            # in the CLI argv for a moment - acceptable on this single-admin box, and the
            # endpoint itself is enrollment-token gated.
            pw = os.environ.get("PASEO_DAEMON_PASSWORD", "")
            try:
                out = subprocess.run(
                    [CLI, "--host", f"{DAEMON_URL}?password={pw}", "daemon", "pair", "--json"],
                    capture_output=True, text=True, timeout=30,
                )
            except Exception as e:
                return self._send(500, {"error": f"cli spawn failed: {type(e).__name__}"})
            if out.returncode != 0:
                return self._send(502, {"error": (out.stderr or out.stdout)[:400]})
            try:
                url = json.loads(out.stdout)["url"]
            except Exception:
                return self._send(502, {"error": "no url in cli output"})
            if not url.startswith("https://app.paseo.sh/#offer="):
                return self._send(502, {"error": "unexpected url"})
            try:
                with open(PAIRING_FILE, "w") as f:
                    f.write(url)
            except OSError as e:
                return self._send(500, {"error": str(e)})
            return self._send(200, {"ok": True})

        def do_GET(self):
            # The sync shim's pull. Exposed only through the tailnet-only dashboard origin
            # (the public /paseo-api/ nginx locations regex-allowlist register/remint/entry).
            if self.path == "/hosts":
                return self._send(200, {"hosts": load_dir()})
            if self.path == "/health":
                return self._send(200, {"ok": True})
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path == "/hosts":
                return self._sync_hosts()
            if self.path == "/seed-hub":
                return self._seed_hub()
            body = self._json_body()
            if not self._authorized(body):
                return self._send(403, {"error": "forbidden"})
            if self.path == "/remint-hub":
                return self._remint_hub()
            if self.path != "/register":
                return self._send(404, {"error": "not found"})
            url = str(body.get("url", ""))
            if not url.startswith("https://app.paseo.sh/#offer=") or len(url) > 4096:
                return self._send(400, {"error": "bad url"})
            name = re.sub(r"[^A-Za-z0-9._-]", "-", str(body.get("name") or "host"))[:40] or "host"
            os.makedirs(REG_DIR, exist_ok=True)
            fn = os.path.join(REG_DIR, f"{int(time.time())}-{name}.json")
            with open(fn, "w") as f:
                json.dump({"name": name, "url": url, "ts": int(time.time())}, f)
            # Optional full host profile (installers send it): the sync shim makes the
            # machine appear in every dashboard without any click.
            prof = body.get("profile")
            if prof is not None:
                if not valid_profile(prof):
                    return self._send(400, {"error": "bad profile"})
                d = load_dir()
                upsert_profile(d, prof)
                save_dir(d)
            return self._send(200, {"ok": True})

        def do_DELETE(self):
            body = self._json_body()
            if not self._authorized(body):
                return self._send(403, {"error": "forbidden"})
            m = re.fullmatch(r"/entry/([A-Za-z0-9._-]{1,80})", self.path)
            if not m:
                return self._send(404, {"error": "not found"})
            fn = os.path.realpath(os.path.join(REG_DIR, m.group(1)))
            if not fn.startswith(os.path.realpath(REG_DIR) + os.sep):
                return self._send(400, {"error": "bad path"})
            try:
                os.remove(fn)
            except FileNotFoundError:
                return self._send(404, {"error": "not found"})
            return self._send(200, {"ok": True})

        def log_message(self, *args):
            pass


    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';

  # Cross-device localStorage sync shim, injected into the dashboard's index.html by nginx.
  # Pulls the shared directory (blocking, so the Expo bundle sees merged storage on first
  # paint), then pushes changed/deleted keys back (debounced). Fully best-effort: any failure
  # just leaves the dashboard device-local, which is the pre-shim behavior.
  syncJs = pkgs.writeText "paseo-sync.js" ''
    (function () {
      var LS = window.localStorage;
      var END = "/paseo-sync/hosts";
      var META_KEY = "@paseo:sync-meta";
      var REGK = "@paseo:daemon-registry";
      var MAXV = 1048576;
      function meta() { try { return JSON.parse(LS.getItem(META_KEY) || "{}"); } catch (e) { return {}; } }
      function setMeta(m) { try { LS.setItem(META_KEY, JSON.stringify(m)); } catch (e) {} }
      function sum(s) {
        var h = 0, n = s.length, i, step = Math.max(1, n >> 10);
        for (i = 0; i < n; i += step) { h = (h * 31 + s.charCodeAt(i)) >>> 0; }
        return h + ":" + n;
      }

      // --- pull: blocking XHR so it finishes before the app bundle boots ---
      try {
        var x = new XMLHttpRequest();
        x.open("GET", END, false);
        x.send();
        if (x.status === 200) {
          var remote = JSON.parse(x.responseText).hosts || {}, m = meta(), k;
          for (k in remote) {
            if (k === META_KEY || !remote[k]) continue;
            var rv = String(remote[k].v || ""), rt = remote[k].ts || 0;
            if (k === REGK) m._reg = rv;
            var loc = LS.getItem(k);
            if (loc === rv) { m[k] = { s: sum(rv), ts: rt }; continue; }
            // Take the remote value only for new keys or keys untouched locally since the
            // last sync; a locally-modified key stays and gets pushed (server-side merge
            // reconciles, and the host array additionally unions by serverId).
            if (loc === null || (m[k] && m[k].s === sum(loc))) {
              try { LS.setItem(k, rv); m[k] = { s: sum(rv), ts: rt }; } catch (e) {}
            }
          }
          setMeta(m);
        }
      } catch (e) {}

      // --- push: changed/new keys (+ deletions), debounced, async ---
      var timer = null;
      function schedule() { if (!timer) timer = setTimeout(flush, 1500); }
      function flush() {
        timer = null;
        try {
          var m = meta(), kv = {}, i, k, v;
          for (i = 0; i < LS.length; i++) {
            k = LS.key(i);
            if (k === META_KEY) continue;
            v = LS.getItem(k) || "";
            if (v.length > MAXV) continue;
            if (!m[k] || m[k].s !== sum(v)) kv[k] = v;
          }
          // Note: whole-key deletions are deliberately NEVER pushed (a cleared/blanked browser
          // must not wipe the shared directory). Only value changes, new keys, and registry
          // host-removal tombstones (below) sync.
          // Tombstone hosts the user removed locally, so the server's union merge lets them go.
          var removed = [];
          if (typeof kv[REGK] === "string" && m._reg) {
            try {
              var prev = JSON.parse(m._reg), curArr = JSON.parse(kv[REGK]), ids = {};
              for (var ci = 0; ci < curArr.length; ci++) if (curArr[ci] && curArr[ci].serverId) ids[curArr[ci].serverId] = 1;
              for (var pi = 0; pi < prev.length; pi++) if (prev[pi] && prev[pi].serverId && !ids[prev[pi].serverId]) removed.push(prev[pi].serverId);
            } catch (e) {}
          }
          if (!Object.keys(kv).length) return;
          fetch(END, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ kv: kv, removed: removed }),
          }).then(function (r) { return r.json(); }).then(function (r) {
            if (!r || !r.ts) return;
            var mm = meta();
            for (var key in kv) {
              if (kv[key] === null) { delete mm[key]; }
              else { mm[key] = { s: sum(kv[key]), ts: r.ts[key] || 0 }; }
            }
            if (typeof kv[REGK] === "string") mm._reg = kv[REGK];
            setMeta(mm);
          }).catch(function () {});
        } catch (e) {}
      }

      try {
        var origSet = Storage.prototype.setItem;
        Storage.prototype.setItem = function (k, v) {
          var r = origSet.call(this, k, v);
          if (this === LS && k !== META_KEY) schedule();
          return r;
        };
      } catch (e) {}

      // Heartbeat: also catches deletes and `localStorage.foo = ...` assignments
      // (those bypass the prototype patch in some engines).
      setInterval(schedule, 30000);
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "hidden") {
          if (timer) { clearTimeout(timer); timer = null; }
          flush();
        }
      });
    })();
  '';

  render = pkgs.writeShellScriptBin "paseo-web-render" ''
    set -euo pipefail
    # Secrets arrive via EnvironmentFile (sops template): PASEO_ENROLLMENT_TOKEN (the URL segment),
    # PASEO_ENROLLMENT_API_KEY (the model key the scripts embed - a LiteLLM key, from
    # ${cfg.model.apiKeySecret}). The hub pairing URL is written by paseo-pair.service.
    umask 027
    export PATH=${lib.makeBinPath (with pkgs; [gettext coreutils findutils jq])}

    # Timer-driven: skip when nothing the cockpit embeds changed (secrets, installer
    # templates, pairing URL, registry). The hour bucket makes the 7-day entry expiry
    # prune within an hour even when nothing else changes.
    stamp=/var/lib/paseo-web/.render-hash
    dyn="$( { cat /var/lib/paseo-web/pairing-url 2>/dev/null; cat /var/lib/paseo-web/hermes-pairing-url 2>/dev/null; cat /var/lib/paseo-web/registry/*.json 2>/dev/null; } | sort | md5sum | cut -d' ' -f1 || true)"
    hash="$(printf '%s' "$(cat /run/secrets/rendered/paseo-web-render.env 2>/dev/null)|''${0}|${machineScriptTmpl}|${slurmScriptTmpl}|${uninstallScriptTmpl}|${slurmUninstallScriptTmpl}|${cockpit}|${paseoFavicon}|$(date -u +%Y%m%d%H)|$dyn" | md5sum | cut -d' ' -f1)"
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ] && [ -L "${webDir}/install" ] && [ -L "${webDir}/cockpit" ]; then
      exit 0
    fi

    pairing=""
    [ -s /var/lib/paseo-web/pairing-url ] && pairing="$(cat /var/lib/paseo-web/pairing-url)"
    export PASEO_PAIRING_URL="$pairing"

    # Hermes machine (paseo-hermes.nix) pairing link, minted by paseo-hermes-pair.service.
    hermes_pairing_html='<p class="empty">Not paired yet - as root: systemctl restart paseo-hermes-pair</p>'
    if [ -s /var/lib/paseo-web/hermes-pairing-url ]; then
      hermes_pairing_html="<pre>$(cat /var/lib/paseo-web/hermes-pairing-url)</pre>"
    fi
    export PASEO_HERMES_PAIRING_HTML="$hermes_pairing_html"

    # Machines that installers registered but no dashboard has claimed yet. Entries older than
    # 7 days are pruned here (writing to the registry dir re-triggers this unit once via the
    # systemd path unit - the prune is then a no-op, so it does not loop).
    machines=""
    now="$(date +%s)"
    for f in $(ls -r /var/lib/paseo-web/registry/*.json 2>/dev/null); do
      ts="$(jq -r '.ts // 0' "$f")"
      if [ $((now - ts)) -gt 604800 ]; then rm -f "$f"; continue; fi
      name="$(jq -r '.name // "host"' "$f")"
      url="$(jq -r '.url // ""' "$f")"
      id="$(basename "$f")"
      hub="https://paseo.hp''${url#https://app.paseo.sh}"
      when="$(date -u -d "@$ts" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$ts")"
      machines="''${machines}<div class=\"entry\"><strong>$name</strong> <span class=\"note\">$when</span>"
      machines="''${machines}<p><a class=\"add\" href=\"$hub\">add to hub dashboard</a>"
      machines="''${machines}<button class=\"del\" data-id=\"$id\">delete</button></p>"
      machines="''${machines}<pre>$url</pre></div>"
    done
    [ -n "$machines" ] || machines='<p class="empty">None waiting - run an installer and its pairing link shows up here.</p>'
    export PASEO_MACHINES_HTML="$machines"

    rel="${webDir}/releases/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$rel/install/$PASEO_ENROLLMENT_TOKEN" "$rel/cockpit"

    export PASEO_ENROLLMENT_TOKEN PASEO_ENROLLMENT_API_KEY
    for f in ${machineScriptTmpl} ${slurmScriptTmpl} ${uninstallScriptTmpl} ${slurmUninstallScriptTmpl}; do
      # basename carries the Nix store hash prefix - strip it and the .tmpl suffix.
      name="$(basename "$f")"
      name="''${name#*-}"
      name="''${name%.tmpl}"
      # envsubst wants the variable names literally (that is its allowlist argument).
      # shellcheck disable=SC2016
      envsubst '$PASEO_ENROLLMENT_TOKEN $PASEO_ENROLLMENT_API_KEY' <"$f" \
        >"$rel/install/$PASEO_ENROLLMENT_TOKEN/$name.sh"
      chmod 0644 "$rel/install/$PASEO_ENROLLMENT_TOKEN/$name.sh"
    done
    # shellcheck disable=SC2016
    envsubst '$PASEO_ENROLLMENT_TOKEN $PASEO_ENROLLMENT_API_KEY $PASEO_PAIRING_URL $PASEO_MACHINES_HTML $PASEO_DAEMON_PASSWORD $PASEO_HERMES_PAIRING_HTML' <${cockpit} >"$rel/cockpit/index.html"
    # The cockpit's <link rel="icon"> is relative, so it resolves under /paseo-c/ on every
    # origin that serves the page (subdomain and funnel path alike) - served from here.
    install -m 0644 ${paseoFavicon} "$rel/cockpit/favicon.ico"
    # Pairing URL is hub-owner material: the cockpit tree itself stays group-readable for
    # nginx only; the token appears there by design (tailnet-only page).
    chmod 0640 "$rel/cockpit/index.html"

    ln -sfn "$rel/cockpit" "${webDir}/cockpit-new"
    mv -Tf "${webDir}/cockpit-new" "${webDir}/cockpit" || { rm -f "${webDir}/cockpit-new"; ln -sfn "$rel/cockpit" "${webDir}/cockpit"; }
    ln -sfn "$rel/install" "${webDir}/install-new"
    mv -Tf "${webDir}/install-new" "${webDir}/install" || { rm -f "${webDir}/install-new"; ln -sfn "$rel/install" "${webDir}/install"; }

    # Keep the last three trees; prune only release dirs.
    find "${webDir}/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf

    printf '%s' "$hash" > "$stamp"
  '';
in {
  options.MODULES.services.paseo = {
    enable = mkEnableOption ''
      the Paseo control plane: a headless Paseo daemon (the hub - dashboard on
      https://paseo.hp, tailnet-only), a self-hosted getpaseo/paseo-relay instance (the one
      public component, on Tailscale Funnel port 10000, traffic E2E-encrypted), a token-gated
      public installer endpoint (/install/<token>/machine.sh, pi + opencode combined, plus
      slurm.sh which sbatch-deploys it) and a tailnet-only cockpit
      page (/paseo-c) with the pairing link and ready-to-paste install commands.

      Note on the relay's public address: Paseo's relay client takes a bare host:port and dials
      the protocol-fixed path /ws (packages/protocol/src/daemon-endpoints.ts buildRelayWebSocketUrl
      - no full-URL/base-path form exists), so a sub-path on the shared 8443 funnel is impossible
      and the relay gets Funnel's third port instead. The 8443 funnel itself carries no relay
      traffic.
    '';

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = "Scrape the relay's Prometheus /metrics (loopback-only) in prometheus.nix.";
    };

    # What the installers bake into the harnesses they configure (pi's models.json, opencode's
    # opencode.json). Before this, those scripts carried FutureLab's URL and key and every installed
    # machine was a direct client of that upstream; going through the gateway instead means one
    # place to mint/revoke keys, meter spend and switch models, and the machines themselves never
    # change. Defaults match MODULES.services.paseo-machine on legion5, so a scripted machine and a
    # NixOS-declared one present the same provider id and model to their user.
    model = {
      baseUrl = mkOption {
        type = types.str;
        default = config.MODULES.services.litellm.public.baseUrl;
        defaultText = lib.literalExpression "MODULES.services.litellm.public.baseUrl";
        description = ''
          OpenAI-compatible endpoint the installed harnesses talk to: this host's LiteLLM gateway
          on its public Funnel path. Public because the scripts advertise "no Tailscale needed" -
          and it has to be that origin rather than https://litellm.hp, which neither resolves nor
          has a certificate these machines trust. Needs MODULES.services.litellm.public.enable:
          with the route missing the scripts install fine and then fail their first request.
        '';
      };

      provider = mkOption {
        type = types.str;
        default = "litellm";
        description = ''
          Provider id written into both harness configs - the first half of the model reference
          users type (`pi --model <provider>/<id>`, opencode's `"model"`). Not "futurelab": the
          name now describes the endpoint the key belongs to, and LiteLLM picks the upstream from
          the model id's own prefix (see `model.id`).
        '';
      };

      providerLabel = mkOption {
        type = types.str;
        default = "LiteLLM (hp)";
        description = "Display name for that provider (opencode's model picker shows it).";
      };

      id = mkOption {
        type = types.str;
        default = "futurelab/qwen3.8-flash-next";
        description = ''
          Model the harnesses start on, spelled the way LiteLLM wants: a `model_name` from the
          gateway's config, which is why it still carries a vendor prefix - "futurelab/..." is the
          wildcard deployment litellm.nix registers under `futurelabEnable`, i.e. the same Aqueduct
          model these scripts used to name directly, one hop further away. The full reference a
          user passes is `<model.provider>/<model.id>`, two prefixes deep; that is how
          MODULES.services.paseo-machine and the interactive setup in users/akos.nix already spell
          it, so pi and opencode both handle it.
        '';
      };

      apiKeySecret = mkOption {
        type = types.str;
        default = "opencode/litellm_api_key";
        example = "litellm_master_key";
        description = ''
          sops secret the installers hand out as the harnesses' model key. It has to be a key
          LiteLLM accepts - which is why this is not `paseo/enrollment_api_key` any more: that one
          holds an Aqueduct key from before the gateway was in front of it, and the gateway rejects
          it (the scripts would install happily and then 401 on the first request).

          The default is the same virtual key the interactive setup in users/akos.nix and
          MODULES.services.paseo-machine use, so scripted machines and declared ones present the
          same credential to the same gateway. Consider minting a dedicated key for it (dashboard ->
          API Keys, capped to `model.id`) and pointing this there: whatever this names is served to
          anyone who knows the enrollment URL and written into ~/.pi and ~/.config/opencode on every
          machine installed. The gateway's master key also works and is the least effort, and the
          most of it.
        '';
      };

      contextLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = 262144;
        example = 131072;
        description = ''
          Context window of model.id in tokens - what the gateway actually serves. Written as pi's
          contextWindow and opencode's limit.context. null omits both and leaves the harnesses
          guessing, and pi guesses 128000: it then compacts its history at contextWindow - 16384
          (~111K) instead of using the window it was handed. Keep this in step with model.id, and
          with MODULES.services.paseo-machine.modelContextLength and the interactive entry in
          users/akos.nix - three copies of one number, because the three install paths describe the
          same model to two harnesses in two dialects.
        '';
      };

      outputLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = 32768;
        example = 16384;
        description = ''
          Max output tokens of model.id: pi's maxTokens, opencode's limit.output. pi guesses 16384
          when unset, which caps every answer and truncates long tool-call arguments (pi fails such
          a call rather than resume it). null omits it.
        '';
      };

      thinkingLevels = mkOption {
        type = types.listOf types.str;
        default = ["low" "medium" "xhigh"];
        example = ["low" "medium"];
        description = ''
          Thinking levels model.id accepts, weakest first, spelled the way the gateway spells
          `reasoning_effort` (pi's own keys: minimal, low, medium, high, xhigh, max - "off" is
          implied and never listed). Rendered into pi's thinkingLevelMap and opencode's variants,
          exactly as MODULES.services.paseo-machine.modelThinkingLevels does for declared machines.
          Empty installs a non-reasoning model: no variants, and pi's /thinking has nothing to
          offer. A level the gateway does not implement is a request it rejects.
        '';
      };

      thinkingDefault = mkOption {
        type = types.str;
        default = "xhigh";
        example = "medium";
        description = ''
          Thinking level a session starts on: opencode's base model options (what it sends until a
          variant is chosen), and the level the installer merges into ~/.pi/agent/settings.json
          under modelThinkingLevels."<provider>/<id>" - keyed per model, so other models pi might
          drive keep pi's own default. Users can still change it per session (/thinking, opencode's
          variant picker); a re-run of the installer resets it to this. Must be one of
          thinkingLevels.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = thinkingDefaultListed;
        message = "MODULES.services.paseo.model.thinkingDefault = ${cfg.model.thinkingDefault} is not in model.thinkingLevels (${lib.concatStringsSep ", " cfg.model.thinkingLevels}) - the installer would make every machine start on a level the gateway rejects.";
      }
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.paseo needs MODULES.security.sops.enable: daemon password, enrollment token, model key and relay cookie all come from sops.";
      }
      {
        assertion = config.MODULES.networking.traefik.enable && config.MODULES.networking.traefik.funnel.enable;
        message = "MODULES.services.paseo needs MODULES.networking.traefik (with funnel.enable) for the cockpit/installer routes.";
      }
      {
        assertion = config.MODULES.networking.tailscale.enable;
        message = "MODULES.services.paseo needs MODULES.networking.tailscale for the relay's Funnel.";
      }
      {
        # The installers are advertised as needing no Tailscale, so their default model endpoint is
        # the public one - which only exists if litellm.nix registers its route on this host.
        assertion = cfg.model.baseUrl != config.MODULES.services.litellm.public.baseUrl || config.MODULES.services.litellm.public.enable;
        message = ''
          MODULES.services.paseo installs harnesses that point at
          "${cfg.model.baseUrl}" (the default, MODULES.services.litellm.public.baseUrl), but
          MODULES.services.litellm.public.enable is off, so no route answers there: every agent on
          an installed machine would fail its first request. Enable the gateway's public path, or
          set MODULES.services.paseo.model.baseUrl to an endpoint off-tailnet machines can reach.
        '';
      }
      {
        # They would claim the same Funnel origin (PORTS.paseoRelayFunnel).
        assertion = !config.MODULES.services.outline.enable;
        message = "MODULES.services.paseo and Outline's public Funnel both want PORTS.paseoRelayFunnel; enable only one.";
      }
    ];

    # --- Users / state --------------------------------------------------------------------------
    users.groups.paseo = {};
    users.groups.paseo-web = {};

    users.users.paseo = {
      isSystemUser = true;
      group = "paseo";
      extraGroups = ["paseo-web"];
      home = "/var/lib/paseo";
      description = "Paseo hub daemon";
    };
    users.users.paseo-relay = {
      isSystemUser = true;
      group = "paseo";
      description = "Paseo relay (Elixir)";
    };
    users.users.paseo-registry = {
      isSystemUser = true;
      group = "paseo-registry";
      # /var/lib/paseo-web itself is 0750 root:paseo-web - needed to reach the registry dir.
      extraGroups = ["paseo-web"];
      description = "Paseo pairing-link registry (installer POST endpoint)";
    };
    users.groups.paseo-registry = {};
    # nginx must read the rendered install tree + cockpit.
    users.users.nginx.extraGroups = ["paseo-web"];

    systemd.tmpfiles.rules = [
      "d /var/lib/paseo 0700 paseo paseo - -"
      "d /var/lib/paseo-web 0750 root paseo-web - -"
      "d /var/lib/paseo-web/releases 0750 root paseo-web - -"
      "d /var/lib/paseo-web/registry 0750 paseo-registry paseo-registry - -"
    ];

    # --- Secrets --------------------------------------------------------------------------------
    # The daemon/relay units read their secret directly from its file (the wrappers run as the
    # service user, so the file carries that user's group). sops.secrets also handles
    # restart-on-rotation via restartUnits. (systemd EnvironmentFiles= deliberately avoided: the
    # PID1 that starts these units after an activation may predate systemd 253 and would
    # silently ignore the key.)
    sops.secrets = {
      "paseo/daemon_password" = {
        path = "/run/secrets/paseo-daemon_password";
        owner = "root";
        group = "paseo";
        mode = "0440";
        restartUnits = ["paseo-daemon.service"];
      };
      "paseo/relay_release_cookie" = {
        path = "/run/secrets/paseo-relay_release_cookie";
        owner = "root";
        # Group must be the relay unit's runtime Group= (paseo), not the user's primary group.
        group = "paseo";
        mode = "0440";
        restartUnits = ["paseo-relay.service"];
      };
      # Read by root:root-render + the registry service (token check); nginx never sees it raw.
      "paseo/enrollment_token" = {
        owner = "root";
        group = "paseo-registry";
        mode = "0440";
      };
      # The model key the installers embed - a LiteLLM key, see MODULES.services.paseo.model.
      "${cfg.model.apiKeySecret}" = {};
    };

    sops.templates."paseo-web-render.env" = {
      owner = "root";
      content = ''
        PASEO_ENROLLMENT_TOKEN=${config.sops.placeholder."paseo/enrollment_token"}
        PASEO_ENROLLMENT_API_KEY=${config.sops.placeholder."${cfg.model.apiKeySecret}"}
        PASEO_DAEMON_PASSWORD=${config.sops.placeholder."paseo/daemon_password"}
      '';
      restartUnits = ["paseo-web-render.service"];
    };

    # The registry mints hub pairing links on demand, so it needs the daemon password.
    sops.templates."paseo-registry.env" = {
      owner = "root";
      group = "paseo-registry";
      mode = "0440";
      content = ''
        PASEO_DAEMON_PASSWORD=${config.sops.placeholder."paseo/daemon_password"}
      '';
      restartUnits = ["paseo-registry.service"];
    };

    # --- Relay ------------------------------------------------------------------------------------
    systemd.services.paseo-relay = {
      description = "Paseo relay (public, WebSocket-only, zero-knowledge)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Loopback listener; the Funnel (tailscale serve, below) is its only way in.
      environment = {
        PASEO_RELAY_HOST = "127.0.0.1";
        PASEO_RELAY_PORT = toString config.PORTS.paseoRelay;
        RELEASE_NODE = "paseo-relay@localhost";
      };
      serviceConfig = {
        # The mix-release launcher wants a writable base; the store paths it defaults to are
        # read-only, so point RELEASE_TMP/MUTABLE/LOG_DIR at the state dir (%S).
        Environment = [
          "RELEASE_TMP=%S"
          "RELEASE_MUTABLE_DIR=%S"
          "RELEASE_LOG_DIR=%S"
        ];
        ExecStart = "${relayStart}/bin/paseo-relay-start";
        User = "paseo-relay";
        Group = "paseo";
        StateDirectory = "paseo-relay";
        Restart = "always";
        RestartSec = 5;
        # The release's own launcher double-forks-ish (wrapper runs the beam in the
        # foreground); Type=exec keeps systemd's view honest.
        Type = "exec";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # the JIT-less BEAM is fine but beam.smp mmaps+exec's its own
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        CapabilityBoundingSet = "";
      };
    };

    MODULES.networking.tailscale.serve.paseo-relay = {
      type = "funnel";
      target = "http://127.0.0.1:${toString config.PORTS.paseoRelay}";
      httpsPort = config.PORTS.paseoRelayFunnel;
    };

    # --- Hub daemon -------------------------------------------------------------------------------
    systemd.services.paseo-daemon = {
      description = "Paseo hub daemon (dashboard + agent runner for this host)";
      wantedBy = ["multi-user.target"];
      after = ["paseo-relay.service" "network-online.target"];
      wants = ["paseo-relay.service" "network-online.target"];
      path = [pkgs.nodejs_24 pkgs.git pkgs.openssh pkgs.openssl];
      environment = {
        PASEO_HOME = "/var/lib/paseo";
        PASEO_LISTEN = "127.0.0.1:${toString config.PORTS.paseoDaemon}";
        PASEO_WEB_UI_ENABLED = "true";
        PASEO_TRUSTED_PROXIES = "127.0.0.1/32";
        PASEO_HOSTNAMES = "${traefik.hostOf "paseo"},localhost,127.0.0.1";
        PASEO_RELAY_ENABLED = "true";
        PASEO_RELAY_ENDPOINT = relayPublicHost;
        PASEO_RELAY_PUBLIC_ENDPOINT = relayPublicHost;
        PASEO_RELAY_USE_TLS = "true";
        PASEO_RELAY_PUBLIC_USE_TLS = "true";
      };
      serviceConfig = {
        ExecStart = "${daemonStart}/bin/paseo-daemon-start";
        User = "paseo";
        Group = "paseo";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/var/lib/paseo"];
        StateDirectory = "paseo";
        SystemCallArchitectures = "native";
      };
    };

    # Generate the hub's relay pairing offer once and leave it for the cockpit page.
    # Re-run (systemctl restart paseo-pair) to rotate an already-consumed link.
    systemd.services.paseo-pair = {
      description = "Generate the Paseo hub pairing URL for the cockpit page";
      wantedBy = ["multi-user.target"];
      after = ["paseo-daemon.service"];
      requires = ["paseo-daemon.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Runs as root only because the password lives in the daemon's env file; the offer
      # itself is produced by the daemon over loopback and needs no home access.
      path = [pkgs.curl];
      script = ''
        set -euo pipefail
        [ -s ${webDir}/pairing-url ] && exit 0
        PASEO_PASSWORD="$(cat ${config.sops.secrets."paseo/daemon_password".path})"
        for _ in $(seq 1 60); do
          curl -sf http://127.0.0.1:${toString config.PORTS.paseoDaemon}/api/health >/dev/null 2>&1 && break
          sleep 1
        done
        url="$(${paseoCli}/bin/paseo --host "tcp://127.0.0.1:${toString config.PORTS.paseoDaemon}?password=$PASEO_PASSWORD" daemon pair --json \
          | ${pkgs.jq}/bin/jq -r '.url // empty')"
        [ -n "$url" ] || { echo "paseo pair returned no URL" >&2; exit 1; }
            umask 027
            printf '%s' "$url" > ${webDir}/pairing-url
            # Group-writable so the registry service can re-mint the link on demand (button).
            chgrp paseo-web ${webDir}/pairing-url
            chmod 0660 ${webDir}/pairing-url
            # Seed the hub itself into the cross-device sync directory (loopback-only endpoint;
            # registry may still be starting, hence the retry). Best-effort.
            PROFILE="$(PASEO_PASSWORD="$PASEO_PASSWORD" ${pkgs.nodejs}/bin/node -e 'const fs=require("fs");const u=fs.readFileSync("${webDir}/pairing-url","utf8").trim();const o=JSON.parse(Buffer.from(u.slice(u.indexOf("#offer=")+7).replace(/-/g,"+").replace(/_/g,"/"),"base64").toString());process.stdout.write(JSON.stringify({profile:{serverId:o.serverId,label:"hp",password:process.env.PASEO_PASSWORD,connections:[{type:"relay",relayEndpoint:o.relay.endpoint,useTls:o.relay.useTls!==false,daemonPublicKeyB64:o.daemonPublicKeyB64}],createdAt:new Date().toISOString()}}))' 2>/dev/null || true)"
            if [ -n "$PROFILE" ]; then
              for _ in $(seq 1 5); do
                curl -fsS -m 10 -X POST -H 'content-type: application/json' --data "$PROFILE" \
                  http://127.0.0.1:${toString config.PORTS.paseoRegistry}/seed-hub >/dev/null 2>&1 && break
                sleep 2
              done
            fi
      '';
    };

    # --- Cockpit + installer statics --------------------------------------------------------------
    systemd.services.paseo-web-render = {
      description = "Render the Paseo cockpit page and token-gated installer tree";
      wantedBy = ["multi-user.target"];
      after = ["paseo-pair.service" "paseo-daemon.service"];
      requires = ["paseo-pair.service"];
      # No RemainAfterExit: the 30s re-render timer needs the unit to go inactive after each
      # pass (OnUnitInactiveSec).
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -a
        . ${config.sops.templates."paseo-web-render.env".path}
        set +a
        ${render}/bin/paseo-web-render
        # Re-render once the pairing URL exists (pair unit may finish after the first pass).
        chgrp -R paseo-web ${webDir}/releases || true
        chmod -R g+rX ${webDir}/releases || true
      '';
    };

    # Re-render the cockpit when anything it embeds changes (installer POSTs / cockpit deletes /
    # 7-day prune). A path unit can't watch a directory's contents here, so a light timer
    # re-runs the render script, which no-ops when a content hash is unchanged.
    systemd.timers.paseo-web-render = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "15s";
        # Note: the service must NOT use RemainAfterExit for this to re-arm (an always-active
        # unit never goes inactive, and OnUnitActiveSec stopped re-firing in practice).
        OnUnitInactiveSec = "30s";
        Unit = "paseo-web-render.service";
      };
    };

    systemd.services.paseo-registry = {
      description = "Paseo pairing-link registry (installer POST endpoint, token-gated)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = {
        PASEO_REGISTRY_DIR = "/var/lib/paseo-web/registry";
        PASEO_TOKEN_FILE = config.sops.secrets."paseo/enrollment_token".path;
        PASEO_REGISTRY_PORT = toString config.PORTS.paseoRegistry;
        PASEO_CLI = "${paseoCli}/bin/paseo";
        PASEO_DAEMON_URL = "tcp://127.0.0.1:${toString config.PORTS.paseoDaemon}";
        PASEO_PAIRING_FILE = "/var/lib/paseo-web/pairing-url";
        # The CLI writes scratch state under HOME; PrivateTmp makes it per-unit.
        HOME = "/tmp";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${registryPy}";
        EnvironmentFile = config.sops.templates."paseo-registry.env".path;
        User = "paseo-registry";
        Group = "paseo-registry";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/var/lib/paseo-web/registry" "/var/lib/paseo-web/pairing-url"];
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = ["AF_INET"];
        CapabilityBoundingSet = "";
        LockPersonality = true;
      };
    };

    services.nginx = {
      enable = true;
      # Dashboard origin (tailnet-only subdomain -> Traefik -> here). nginx sits in front of
      # the daemon solely to inject the localStorage sync shim and expose its endpoints; the
      # app itself (API + websockets) is proxied through untouched.
      virtualHosts."paseo.hp" = {
        listen = [
          {
            addr = "127.0.0.1";
            port = config.PORTS.paseoWeb;
          }
        ];
        locations."= /paseo-sync.js" = {
          alias = "${syncJs}";
          extraConfig = ''
            default_type application/javascript;
            add_header Cache-Control "no-store";
          '';
        };
        # Sync directory (GET pull / POST push). Deliberately NOT reachable through the public
        # /paseo-api/ allowlist below: localStorage holds host passwords.
        locations."/paseo-sync/" = {
          proxyPass = "http://127.0.0.1:${toString config.PORTS.paseoRegistry}/";
          extraConfig = ''
            client_max_body_size 8m;
            add_header Cache-Control "no-store";
          '';
        };
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.PORTS.paseoDaemon}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            # sub_filter needs the upstream to send the page uncompressed.
            proxy_set_header Accept-Encoding "";
            sub_filter '</head>' '<script src="/paseo-sync.js"></script></head>';
            sub_filter_once on;
          '';
        };
      };
      virtualHosts."paseo.internal" = {
        default = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = config.PORTS.paseoWeb;
          }
        ];
        extraConfig = ''
          absolute_redirect off;
        '';
        # Subdomain origin (paseo-c.hp): land straight on the cockpit.
        locations."= /".return = "302 /paseo-c/";
        locations."= /paseo".return = "302 ${traefik.urlOf "paseo"}/";
        locations."= /paseo-c".return = "301 /paseo-c/";
        locations."/paseo-c/" = {
          alias = "${webDir}/cockpit/";
          index = "index.html";
          extraConfig = ''
            try_files $uri $uri/ =404;
          '';
        };
        # Token IS the path segment: a wrong/missing token never names an existing directory.
        locations."= /install".return = "404";
        locations."= /install/".return = "404";
        locations."/install/" = {
          alias = "${webDir}/install/";
          extraConfig = ''
            autoindex off;
            try_files $uri =404;
          '';
        };
        # Token-gated machine pairing-link registry (installer POSTs, cockpit DELETEs).
        # Regex allowlist on purpose: the registry also serves the password-bearing sync
        # directory at /hosts, which must stay reachable only via the tailnet-only dashboard
        # origin. rewrite strips the /paseo-api prefix before proxying.
        locations."~ ^/paseo-api/(register|remint-hub)$" = {
          proxyPass = "http://127.0.0.1:${toString config.PORTS.paseoRegistry}";
          extraConfig = ''
            rewrite ^/paseo-api/(.*)$ /$1 break;
          '';
        };
        locations."~ ^/paseo-api/entry/[A-Za-z0-9._-]+$" = {
          proxyPass = "http://127.0.0.1:${toString config.PORTS.paseoRegistry}";
          extraConfig = ''
            rewrite ^/paseo-api/(.*)$ /$1 break;
          '';
        };
        locations."/" = {
          return = "404";
        };
      };
    };

    # --- Routing ---------------------------------------------------------------------------------
    # Dashboard: its own tailnet subdomain, cert from step-ca, DNS from dns.nix; nothing on this
    # listener is ever reachable off the tailnet. Served through nginx (see vhost paseo.hp) so
    # the localStorage sync shim gets injected; the app itself is proxied to the daemon.
    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.paseo = nginxUrl;
    # Cockpit on its own subdomain too (paseo-c.hp); the /paseo-c/ funnel path stays for
    # convenience. Subdomains are tailnet-only by nature: DNS only resolves on the tailnet and
    # the step-ca cert isn't trusted externally.
    MODULES.networking.traefik.services.paseo-c = "127.0.0.1:${toString config.PORTS.paseoWeb}";

    MODULES.networking.traefik.funnel = {
      enable = true;
      routes = {
        # Tailnet-only (existing !HeaderRegexp(Tailscale-Funnel-Request) mechanism; Funnel
        # requests get the module's noop 404 instead).
        paseo = {
          pathPrefix = "/paseo";
          target = nginxUrl;
          tailnetOnly = true;
        };
        paseo-c = {
          pathPrefix = "/paseo-c";
          target = nginxUrl;
          tailnetOnly = true;
        };
        # Public on purpose: this is the only way onto non-tailnet machines. The token in the
        # path is the authentication.
        paseo-install = {
          pathPrefix = "/install";
          target = nginxUrl;
        };
        # Public too (remote installers POST their link); every request must carry the
        # enrollment token in the JSON body - the endpoint is inert without it.
        paseo-api = {
          pathPrefix = "/paseo-api";
          target = nginxUrl;
        };
      };
    };

    # --- Monitoring / homepage -------------------------------------------------------------------
    services.prometheus.scrapeConfigs = mkIf cfg.metrics [
      {
        job_name = "paseo-relay";
        static_configs = [
          {
            targets = ["127.0.0.1:${toString config.PORTS.paseoRelay}"];
          }
        ];
        metrics_path = "/metrics";
      }
    ];

    MODULES.services.homepage.services.paseo = {
      href = "${traefik.urlOf "paseo"}/";
      icon = paseoFaviconUrl;
      description = "Paseo agent control plane (hub)";
    };

    # traefik.services.paseo-c above already generates a homepage tile for it; this enriches
    # that same entry (same attr name merges) with a description and the hub's favicon.
    MODULES.services.homepage.services."paseo-c" = {
      description = "Paseo cockpit (pairing link, installers)";
      icon = paseoFaviconUrl;
    };
  };
}
