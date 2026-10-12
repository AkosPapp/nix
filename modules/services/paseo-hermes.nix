{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.MODULES.services.paseo-hermes;
  hermes = config.services.hermes-agent;

  paseoCli = pkgs.callPackage ../../packages/paseo/cli.nix {};

  # Same public relay endpoint the hub daemon dials (modules/services/paseo.nix): bare host:port,
  # TLS on, protocol-fixed path /ws. The funnel FQDN resolves to this machine's own tailnet IP,
  # which is exactly the destination the hermes-egress rule in hermes-agent.nix pins.
  relayPublicHost = "${config.networking.fqdn}:${toString config.PORTS.paseoRelayFunnel}";

  # State lives inside Hermes' state dir so it lands in the sandbox's BindPaths - /var/lib/paseo
  # and the hub's 6767 are deliberately not touched.
  paseoHome = "${hermes.stateDir}/.paseo";
  hermesHome = "${hermes.stateDir}/.hermes";
  listenHost = "127.0.0.1:${toString config.PORTS.paseoHermesDaemon}";

  # The pairing URL is written next to the hub's (which the cockpit already renders from) so the
  # root-owned render timer in paseo.nix can pick it up without needing hermes-home access.
  pairFile = "/var/lib/paseo-web/hermes-pairing-url";

  # ACP entry point for the Paseo provider. Hermes' own console script, wrapped so the store path
  # baked into config.json has one stable name; config.json is re-installed on every start (see
  # installConfig) so a rebuild's new hash self-heals.
  acpWrapper = pkgs.writeShellScriptBin "hermes-acp-paseo" ''
    exec ${hermes.package}/bin/hermes-acp "$@"
  '';

  # The provider config the daemon serves Hermes from. NO SECRETS in here (it is a Nix store
  # file): hermes-acp reads the LiteLLM key itself from $HERMES_HOME/.env, same as the gateway.
  providerConfig = pkgs.writeText "paseo-hermes-config.json" (builtins.toJSON {
    version = 1;
    agents.providers.hermes = {
      extends = "acp";
      label = "Hermes";
      command = ["${acpWrapper}/bin/hermes-acp-paseo"];
      env.HERMES_HOME = hermesHome;
    };
  });

  # Copy-if-changed, run as the service user (pre-start): the daemon rewrites its own
  # config.json at runtime (the hub's /var/lib/paseo/config.json proves it), so this must be a
  # real file, not a store symlink, and must re-assert the provider entry on every start.
  installConfig = pkgs.writeShellScriptBin "paseo-hermes-install-config" ''
    set -eu
    if ! cmp -s ${providerConfig} ${paseoHome}/config.json 2>/dev/null; then
      install -m 600 ${providerConfig} ${paseoHome}/config.json
    fi
  '';

  # Daemon launcher. NOT the hub's direct-cat wrapper: this unit runs inside the Hermes sandbox,
  # whose InaccessiblePaths hides /run/secrets from the service process - the password arrives via
  # LoadCredential instead (the pattern matrix-reader.service already uses in this same sandbox).
  daemonStart = pkgs.writeShellScriptBin "paseo-hermes-daemon-start" ''
    set -euo pipefail
    export PASEO_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/daemon_password")"
    exec ${paseoCli}/bin/paseo daemon run
  '';
in {
  options.MODULES.services.paseo-hermes = {
    enable = mkEnableOption ''
      a second Paseo daemon running as the Hermes user: loopback-only, dialing out to the hub's
      relay like a remote harness machine, exposing Hermes (ACP over stdio) as the "Hermes" custom
      provider. Pairing: paseo-hermes-pair.service mints the link into the cockpit and seeds the
      host profile ("hermes-hp") into the registry's cross-device sync directory.
    '';
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.services.paseo.enable;
        message = "MODULES.services.paseo-hermes rides on the Paseo control plane: enable MODULES.services.paseo on the same host (relay, registry, cockpit).";
      }
      {
        assertion = config.MODULES.services.hermes-agent.enable;
        message = "MODULES.services.paseo-hermes runs Hermes' ACP adapter as uid hermes: enable MODULES.services.hermes-agent on the same host.";
      }
      {
        # The egress rule hermes-agent.nix adds for this module pins the destination IP.
        assertion = config.MODULES.networking.tailscale.hostIP != null;
        message = "MODULES.services.paseo-hermes needs MODULES.networking.tailscale.hostIP: the hermes-egress relay rule is destination-pinned and must not open 100.64.0.0/10.";
      }
    ];

    # Daemon state dir (0700: it will hold the daemon keypair and session data).
    systemd.tmpfiles.rules = [
      "d ${paseoHome} 0700 ${hermes.user} ${hermes.user} - -"
    ];

    sops.secrets."paseo/hermes_daemon_password" = {
      restartUnits = ["paseo-hermes.service"];
    };

    systemd.services.paseo-hermes = {
      description = "Paseo daemon for Hermes (ACP provider runner, loopback-only, uid hermes)";
      wantedBy = ["multi-user.target"];
      # The relay dial needs the Funnel listener up; Restart=always covers a slower boot anyway.
      after = ["network-online.target" "tailscale-funnel-paseo-relay.service"];
      wants = ["network-online.target"];
      # ps: the daemon's provider process-tree watcher (spawn ps --ppid ...) crashes the worker
      # without it; tar+bzip2: its background speech-model unpacks; git/openssh: harness parity
      # with the hub daemon's PATH.
      path = with pkgs; [
        bzip2
        coreutils
        curl
        git
        gnutar
        nodejs_24
        openssh
        openssl
        procps
        which
      ];
      environment = {
        PASEO_HOME = paseoHome;
        PASEO_LISTEN = listenHost;
        PASEO_WEB_UI_ENABLED = "false";
        PASEO_RELAY_ENABLED = "true";
        PASEO_RELAY_ENDPOINT = relayPublicHost;
        PASEO_RELAY_PUBLIC_ENDPOINT = relayPublicHost;
        PASEO_RELAY_USE_TLS = "true";
        PASEO_RELAY_PUBLIC_USE_TLS = "true";
        HOME = hermes.stateDir;
        HERMES_HOME = hermesHome;
      };
      serviceConfig = let
        sandbox = config.MODULES.services.hermes-agent.paseoHermesSandbox;
      in
        sandbox
        // {
          ExecStartPre = "${installConfig}/bin/paseo-hermes-install-config";
          ExecStart = "${daemonStart}/bin/paseo-hermes-daemon-start";
          User = hermes.user;
          Restart = "always";
          RestartSec = 5;
          LoadCredential = ["daemon_password:${config.sops.secrets."paseo/hermes_daemon_password".path}"];
        };
    };

    # Modeled on paseo-pair.service (which it mirrors down to running as root: the password file
    # is root-readable only, and the offer itself is produced by the daemon over loopback).
    # Re-mint a single-use link with: rm /var/lib/paseo-web/hermes-pairing-url && systemctl restart paseo-hermes-pair
    systemd.services.paseo-hermes-pair = {
      description = "Pair the Hermes Paseo daemon into the hub (cockpit link + host profile seed)";
      wantedBy = ["multi-user.target"];
      after = ["paseo-hermes.service" "paseo-registry.service"];
      requires = ["paseo-hermes.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [pkgs.curl];
      script = ''
        set -euo pipefail
        [ -s ${pairFile} ] && exit 0
        PASEO_PASSWORD="$(cat ${config.sops.secrets."paseo/hermes_daemon_password".path})"
        # /api/health answers before the daemon's WS layer finishes warming (early attempts get
        # 503) - retry the pairing call itself, same trap the paseo.nix installer scripts document.
        url=""
        for _ in $(seq 1 30); do
          url="$(${paseoCli}/bin/paseo --host "tcp://${listenHost}?password=$PASEO_PASSWORD" daemon pair --json 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.url // empty' || true)"
          [ -n "$url" ] && break
          sleep 2
        done
        [ -n "$url" ] || { echo "paseo-hermes pair got no URL after 60s (daemon unreachable at ${listenHost}?)" >&2; exit 1; }
        umask 027
        printf '%s' "$url" > ${pairFile}
        # Group paseo-web so the cockpit's render timer (same contract as the hub's pairing-url).
        chgrp paseo-web ${pairFile}
        chmod 0660 ${pairFile}
        # Seed the full host profile into the registry's cross-device sync directory, so
        # hermes-hp shows up in every dashboard without any click (loopback-only endpoint;
        # registry may still be starting, hence the retry). Best-effort.
        PROFILE="$(PASEO_PASSWORD="$PASEO_PASSWORD" ${pkgs.nodejs}/bin/node -e 'const fs=require("fs");const u=fs.readFileSync("${pairFile}","utf8").trim();const o=JSON.parse(Buffer.from(u.slice(u.indexOf("#offer=")+7).replace(/-/g,"+").replace(/_/g,"/"),"base64").toString());process.stdout.write(JSON.stringify({profile:{serverId:o.serverId,label:"hermes-hp",password:process.env.PASEO_PASSWORD,connections:[{type:"relay",relayEndpoint:o.relay.endpoint,useTls:o.relay.useTls!==false,daemonPublicKeyB64:o.daemonPublicKeyB64}],createdAt:new Date().toISOString()}}))' 2>/dev/null || true)"
        if [ -n "$PROFILE" ]; then
          for _ in $(seq 1 5); do
            curl -fsS -m 10 -X POST -H 'content-type: application/json' --data "$PROFILE" \
              http://127.0.0.1:${toString config.PORTS.paseoRegistry}/seed-hub >/dev/null 2>&1 && break
            sleep 2
          done
        fi
      '';
    };
  };
}
