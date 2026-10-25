{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  # Submodule which validates a single "serve" configuration
  serveSubmodule = {config, ...}: {
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["serve" "funnel"];
        default = "serve";
        description = "Type identifier for this submodule; must be 'serve' or 'funnel'.";
      };

      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Target for the serve command (e.g., 'https://localhost:3000', '/path/to/file', or 'text:Hello').";
      };

      httpPort = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Expose an HTTP server at the specified port. only with 'serve' type.";
      };

      httpsPort = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Expose an HTTPS server at the specified port.";
      };

      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Serve for a service with distinct virtual IP instead on node itself.";
      };

      setPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Appends the specified path to the base URL for accessing the underlying service.";
      };

      tcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [];
        description = "Expose TCP forwarders at the specified ports.";
      };

      tlsTermTcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [];
        description = "Expose TLS-terminated TCP forwarders at the specified ports.";
      };

      tun = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Forward all traffic to the local machine (default false). Only supported for services.";
      };

      yes = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Update without interactive prompts (default false).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional arbitrary flags passed to 'tailscale serve'.";
      };
    };
  };
in {
  options = {
    MODULES.networking.tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Tailscale VPN";
      };
      hostIP = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The Tailscale IP address of this node.";
      };
      watchdog = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Restart tailscaled when it has been continuously offline for
            `failures` consecutive checks. Guards against the wedged-session
            failure mode seen on hp (2026-10-25): tailscaled keeps running but
            never recovers its NAT mapping / control connection, so the node
            vanishes from the tailnet for hours with no unit failure anywhere.
          '';
        };
        intervalSec = lib.mkOption {
          type = lib.types.int;
          default = 90;
          description = "How often the watchdog probe runs.";
        };
        failures = lib.mkOption {
          type = lib.types.int;
          default = 4;
          description = "Consecutive offline probes before a restart is attempted.";
        };
        cooldownSec = lib.mkOption {
          type = lib.types.int;
          default = 1800;
          description = "Minimum spacing between automatic tailscaled restarts.";
        };
      };
      tailnetDnsName = lib.mkOption {
        type = lib.types.str;
        default = "tail546fb.ts.net";
        description = "The Tailnet DNS name of this node.";
      };
      cert = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable automatic TLS certificate generation via Tailscale.";
        };
        domain = lib.mkOption {
          type = lib.types.str;
          default = config.networking.fqdn;
          description = "The domain name for the TLS certificate.";
        };
        certFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/tailscale/cert.pem";
          description = "Path to the TLS certificate file.";
        };
        keyFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/tailscale/key.pem";
          description = "Path to the TLS key file.";
        };
      };

      serve = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule serveSubmodule);
        default = {};
        description = ''
          Attribute set of serve configurations. The attribute name is used as the service name. Example:
            serve = {
              "my-service" = {
                type = "serve";
                httpsPort = 443;
                yes = true;
              };
              "my-other-service" = {
                type = "funnel";
                httpPort = 80;
                setPath = "/app";
              };
            };
          For each entry the following optional keys are supported:
            - type (enum: "serve" | "funnel", default: "serve")
            - target (null | string)
            - httpPort (null | int)
            - httpsPort (null | int)
            - service (null | string)
            - setPath (null | string)
            - tcpPorts (list of ints)
            - tlsTermTcpPorts (list of ints)
            - tun (bool)
            - yes (bool)
            - extraArgs (list of strings)
        '';
      };
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable (
    let
      serveAttrs = config.MODULES.networking.tailscale.serve;
      cfgWatchdog = config.MODULES.networking.tailscale.watchdog;

      # One probe = one tailscale status call. "Offline" NetInfo over N
      # consecutive runs restarts tailscaled; any non-offline probe resets the
      # counter, and a cooldown stops pathological flapping.
      watchdogScript = pkgs.writeShellScript "tailscale-watchdog-check" ''
        set -euo pipefail
        TS="${pkgs-unstable.tailscale}/bin/tailscale"
        JQ="${pkgs.jq}/bin/jq"
        DATE="${pkgs.coreutils}/bin/date"
        LOGGER="${pkgs.util-linux}/bin/logger"
        STATE_DIR="/var/lib/tailscale-watchdog"
        COUNT_FILE="$STATE_DIR/offline-count"
        RESTART_FILE="$STATE_DIR/last-restart"
        THRESHOLD="${toString cfgWatchdog.failures}"
        COOLDOWN="${toString cfgWatchdog.cooldownSec}"
        mkdir -p "$STATE_DIR"

        STATUS="$("$TS" status --json 2>/dev/null)" || true
        if [ -z "$STATUS" ]; then
          echo "status call failed; not counting"
          exit 0
        fi
        STATE="$(printf '%s' "$STATUS" | "$JQ" -r '.BackendState // "Unknown"')"
        OFFLINE="$(printf '%s' "$STATUS" | "$JQ" -r '.NetInfo.Offline // "unknown"')"

        if [ "$STATE" != "Running" ]; then
          echo "backend state '$STATE'; not auto-recoverable without creds, not restarting"
          exit 0
        fi
        if [ "$OFFLINE" != "true" ]; then
          # online, or NetInfo not populated yet (fresh start) - reset the counter
          ${pkgs.coreutils}/bin/rm -f "$COUNT_FILE"
          exit 0
        fi

        N="$(cat "$COUNT_FILE" 2>/dev/null || true)"; N="''${N:-0}"
        N=$((N + 1))
        echo "$N" > "$COUNT_FILE"
        echo "offline $N/$THRESHOLD consecutive probes"
        if [ "$N" -lt "$THRESHOLD" ]; then
          exit 0
        fi

        NOW="$("$DATE" +%s)"
        LAST="$(cat "$RESTART_FILE" 2>/dev/null || true)"; LAST="''${LAST:-0}"
        SINCE=$((NOW - LAST))
        if [ "$SINCE" -lt "$COOLDOWN" ]; then
          echo "cooldown active ($SINCE s < $COOLDOWN s); skipping restart"
          exit 0
        fi

        ${pkgs.coreutils}/bin/rm -f "$COUNT_FILE"
        echo "$NOW" > "$RESTART_FILE"
        "$LOGGER" -t tailscale-watchdog "offline for $THRESHOLD probes; restarting tailscaled"
        "${pkgs.systemd}/bin/systemctl" restart tailscaled.service
      '';

      buildServeFlags = s: let
        httpFlag =
          if s.httpPort == null
          then ""
          else "--http ${toString s.httpPort}";
        httpsFlag =
          if s.httpsPort == null
          then ""
          else "--https ${toString s.httpsPort}";
        serviceFlag =
          if s.service == null
          then ""
          else "--service ${s.service}";
        setPathFlag =
          if s.setPath == null
          then ""
          else "--set-path ${s.setPath}";
        tcpFlags = lib.concatStringsSep " " (lib.map (p: "--tcp ${toString p}") (s.tcpPorts or []));
        tlsTermFlags = lib.concatStringsSep " " (lib.map (p: "--tls-terminated-tcp ${toString p}") (s.tlsTermTcpPorts or []));
        tunFlag =
          if s.tun
          then "--tun"
          else "";
        yesFlag =
          if s.yes
          then "--yes"
          else "";
        extra = lib.concatStringsSep " " (s.extraArgs or []);
      in
        lib.concatStringsSep " " (lib.filter (x: x != "") [httpFlag httpsFlag serviceFlag setPathFlag tcpFlags tlsTermFlags tunFlag yesFlag extra]);

      servicesAttrset =
        lib.mapAttrs' (
          name: s: let
            serviceType = s.type;
            targetArg =
              if s.target != null
              then s.target
              else "";
            svc = {
              description = "Tailscale ${serviceType} ${name}";
              after = ["tailscaled.service" "network-online.target"];
              wants = ["tailscaled.service" "network-online.target"];
              wantedBy = ["multi-user.target"];
              # On boot, tailscaled.service becomes "active" as soon as the daemon process starts,
              # well before it has actually reconnected to the tailnet - `tailscale serve` run any
              # earlier than that fails immediately. Block here until the node has a Tailscale IP
              # (ie. is actually connected), and don't let the burst of quick failures that
              # produces permanently disable retries via systemd's start-limit.
              startLimitIntervalSec = 0;
              serviceConfig = {
                ExecStartPre = "${pkgs.bash}/bin/bash -c 'until ${pkgs-unstable.tailscale}/bin/tailscale ip -4 >/dev/null 2>&1; do sleep 1; done'";
                ExecStart = "${pkgs-unstable.tailscale}/bin/tailscale ${serviceType} ${buildServeFlags s} ${targetArg}";
                User = "root";
                Restart = "always";
                RestartSec = 5;
              };
            };
          in
            lib.nameValuePair "tailscale-${serviceType}-${name}" svc
        )
        serveAttrs;

      watchdogService = {
        description = "Stuck-tailnet watchdog: restart tailscaled after continuous offline";
        after = ["tailscaled.service" "network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${watchdogScript}";
          User = "root";
        };
        # never let a probe failure blackhole the timer
        unitConfig.StartLimitIntervalSec = 0;
      };
    in {
      services.tailscale = {
        enable = true;
        openFirewall = true;
        extraSetFlags = ["--accept-dns=true" "--accept-routes=true"];
        package = pkgs-unstable.tailscale;
      };

      networking = {
        firewall.checkReversePath = "loose";
        domain = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
        fqdn = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
      };

      systemd.services =
        {
          tailscale-cert-renewal = lib.mkIf config.MODULES.networking.tailscale.cert.enable {
            description = "Tailscale Certificate Renewal Service";
            after = ["network.target" "tailscaled.service"];
            wants = ["tailscaled.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "/bin/sh -c \'${pkgs.coreutils}/bin/mkdir -p /var/lib/tailscale && ${pkgs-unstable.tailscale}/bin/tailscale cert --cert-file ${config.MODULES.networking.tailscale.cert.certFile} --key-file ${config.MODULES.networking.tailscale.cert.keyFile} ${config.MODULES.networking.tailscale.cert.domain}\'";
              User = "root";
              Group = "root";
            };
          };
        }
        // servicesAttrset
        // lib.optionalAttrs cfgWatchdog.enable {
          tailscale-watchdog = watchdogService;
        };

      systemd.timers = lib.optionalAttrs cfgWatchdog.enable {
        tailscale-watchdog = {
          description = "Periodic tailscale offline watchdog";
          wantedBy = ["timers.target"];
          timerConfig = {
            Unit = "tailscale-watchdog.service";
            OnBootSec = "5min";
            OnUnitActiveSec = "${toString cfgWatchdog.intervalSec}s";
            AccuracySec = "30s";
          };
        };
      };
    }
  );
}
