# Coroot - full-stack observability: an eBPF-based agent on every host it should see, plus a
# central server (UI, service map, alerting) backed by ClickHouse for flow/snapshot data.
#
# What it visualises of this fleet, and what it cannot:
#   - Docker services: coroot-node-agent reads the host cgroup tree and kernel socket probes, so
#     every container shows up as an application with its requests, errors, connections and logs.
#   - Connections between services (and to the future microVMs): every TCP flow the kernel sees,
#     including the tap interfaces the microVMs will hang off, lands in the service map. Failed or
#     refused flows - e.g. one blocked by the §7 SERVICE_GRAPH nftables ruleset - show up as
#     connection-error edges rather than silently vanishing.
#   - The nftables ruleset itself is NOT drawn: Coroot observes packets, not rules. The rules'
#     shape is declared in SERVICE_GRAPH; Coroot shows what that graph let through.
#   - Inside a microVM: not visible from the host's agent (separate kernel). When §6 lands, give
#     each service VM its own coroot-node-agent; the host-side agent only ever sees the tap side
#     of those connections.
#
# Packaging (2026-10-27): server and node agent are the NATIVE nixpkgs-unstable packages
# (coroot 1.27.4 / coroot-node-agent 1.36.1, both from the shared pkgs-unstable pin - neither
# exists in nixos-26.05). They were docker images before; the agent-server API is versioned
# together, and taking both from one pin is what keeps that pairing guaranteed. ClickHouse
# stays a docker container: its data volume is the only copy of the flow history and there is
# no reason to touch it for a server bump. The docker volumes coroot-data (sqlite) and
# coroot-node-agent-data were lifted/retired by coroot-data-migration; remove them by hand
# once the new generation is confirmed good:
#   docker volume rm coroot-data coroot-node-agent-data
#
# OpenTelemetry: since 1.27 the server ingests OTLP/HTTP on the LISTEN port itself -
# /v1/traces, /v1/logs, /v1/metrics, authenticated with a per-project API key in the
# x-api-key header (project settings in the UI, or POST /api/project/<id>/api_keys).
# Traefik already publishes the listener as https://coroot.<host>, so instrumented apps
# need no new port anywhere:
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://coroot.<host>/v1/traces
#   OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://coroot.<host>/v1/logs
#   OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf  OTEL_METRICS_EXPORTER=none
#   OTEL_EXPORTER_OTLP_HEADERS=x-api-key=<key>
# The gRPC listener is disabled (no PORTS entry; OTLP/HTTP covers traces and logs, and the
# node agent has always pushed over its own protocol).
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.coroot;

  dataDir = "/var/lib/coroot";
  secretsFile = "${dataDir}/secrets.env";

  # The hosts running the server half (clickhouse + coroot + its own agent). Multiple hosts
  # may each run their own server (2026-10-25: per-host Coroot UIs by request - each server
  # visualises only its own host, agentEnable hosts and microVM guests still push to the
  # FIRST server in the list). microVM guests see an empty nixosConfigurations, so they
  # must pass collectorUrl explicitly.
  serverHosts = builtins.filter (host: nixosConfigurations.${host}.config.MODULES.services.coroot.enable) (builtins.attrNames nixosConfigurations);
  serverHost =
    if serverHosts != []
    then lib.head serverHosts
    else null;

  # Agents push to the server; loopback when this host is the server, other hosts' agents reach it
  # over Tailscale - the only network these machines share (same reasoning as litellm.nix).
  collectorUrl =
    if cfg.collectorUrl != null
    then cfg.collectorUrl
    else if cfg.enable
    then "http://127.0.0.1:${toString config.PORTS.coroot}"
    else if serverHost != null
    then "http://${nixosConfigurations.${serverHost}.config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.coroot}"
    else throw "MODULES.services.coroot: an agent runs on this host, but no flake host has the Coroot server enabled and collectorUrl is null - nowhere to push.";

  # ClickHouse is configured (not just mapped) onto loopback: with host networking it would
  # otherwise bind its default 0.0.0.0:9000, which also collides with step-ca's PORTS.stepCa.
  clickhouseConfig = pkgs.writeText "coroot-clickhouse.xml" ''
    <clickhouse>
      <listen_host>127.0.0.1</listen_host>
      <tcp_port>${toString config.PORTS.corootClickhouseNative}</tcp_port>
      <http_port>${toString config.PORTS.corootClickhouseHttp}</http_port>
      <logger>
        <level>warning</level>
        <console>true</console>
      </logger>
      <!-- Coroot queries ClickHouse heavily; its own system-log tables then dominate the disk.
           Disabled per Coroot's own docker-compose and the docs' EE guidance. -->
      <query_thread_log remove="remove"/>
      <query_log remove="remove"/>
      <text_log remove="remove"/>
      <trace_log remove="remove"/>
      <metric_log remove="remove"/>
      <asynchronous_metric_log remove="remove"/>
      <session_log remove="remove"/>
      <part_log remove="remove"/>
      <latency_log remove="remove"/>
      <processors_profile_log remove="remove"/>
      <!-- Per-host servers also land on smaller boxes (akos01: 12 GB total shared with
           grafana/loki/prometheus): cap the server instead of trusting ClickHouse's
           optimistic default (~90% of RAM). Single-node telemetry volumes stay far below
           this; a big host would push fine anyway. -->
      <max_server_memory_usage>3000000000</max_server_memory_usage>
      <profiles>
        <default>
          <log_queries>0</log_queries>
          <log_query_threads>0</log_query_threads>
          <log_processors_profiles>0</log_processors_profiles>
        </default>
      </profiles>
    </clickhouse>
  '';
in {
  options.MODULES.services.coroot = {
    enable = mkEnableOption ''
      a Coroot observability server on this host: ClickHouse + the Coroot app + a local
      coroot-node-agent. Uses the host's existing Prometheus (PORTS.prometheus) as its
      metrics datasource, and publishes the UI through Traefik (coroot.<this host>). Each
      enabled host is its own independent server - the local agent pushes to it over
      loopback and the data stays local. A host that should report to ANOTHER host's
      server uses MODULES.services.coroot.agentEnable instead; its agent pushes over
      Tailscale to the first enabled server host.
    '';

    agentEnable = mkEnableOption ''
      coroot-node-agent only (no server): an eBPF-based, privileged host agent reporting
      processes, containers, network flows, logs and GPU stats to the Coroot server. Loopback-only
      listener; all communication is outbound.
    '';

    collectorUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://100.83.255.5:8080";
      description = ''
        Override for the agent's server endpoint. Null (the default) derives it: loopback on the
        server host, the server host's Tailscale IP everywhere else.
      '';
    };

    clickhouseImage = mkOption {
      type = types.str;
      default = "clickhouse/clickhouse-server:24.3";
      description = ''
        ClickHouse image; the tag this fleet's flow-history volume was created under and the
        one Coroot's own docker install pinned when the server arrived (verified live on
        akos01 across the 1.9.9 -> 1.27.4 server bump - coroot's ClickHouse migrations are
        append-only, the newer server runs the older server fine).
      '';
    };
  };

  config = lib.mkMerge [
    # ---------------------------------------------------------------- agent (server or not) --
    # Native unit, not a container: eBPF needs the same privileges either way, and as a host
    # service it reads /sys/fs/cgroup directly instead of through docker's /host bind. The
    # package comes from pkgs-unstable to stay version-paired with the server half.
    (mkIf (cfg.enable || cfg.agentEnable) {
      assertions = [
        {
          assertion = cfg.enable || serverHosts != [] || cfg.collectorUrl != null;
          message = ''
            MODULES.services.coroot.agentEnable is set but no host in the flake has
            MODULES.services.coroot.enable and collectorUrl is null - the agent would have
            nowhere to push.
          '';
        }
      ];

      systemd.services.coroot-node-agent = {
        description = "Coroot node agent";
        wantedBy = ["multi-user.target"];
        # Push-only, but the collector lives on the tailnet, so tailscaled must be up first;
        # on the server host, start after coroot itself so the first push lands.
        after =
          ["network-online.target" "tailscaled.service"]
          ++ lib.optionals cfg.enable ["coroot.service"];
        wants = ["network-online.target"] ++ lib.optionals cfg.enable ["coroot.service"];
        requires = ["tailscaled.service"];
        serviceConfig = {
          Restart = "always";
          RestartSec = "5s";
          # The only writable state is the WAL spool for push retries.
          StateDirectory = "coroot-node-agent";
          ExecStart = lib.concatStringsSep " " [
            "${pkgs-unstable.coroot-node-agent}/bin/coroot-node-agent"
            # Loopback: nothing connects TO the agent (it pushes), and the port serves plain
            # /metrics. The package default is 0.0.0.0:80 - always override it.
            "--listen=127.0.0.1:${toString config.PORTS.corootNodeAgent}"
            "--collector-endpoint=${collectorUrl}"
            # cgroup v2, this machine's own tree (the docker variant needed /host).
            "--cgroupfs-root=/sys/fs/cgroup"
            "--wal-dir=/var/lib/coroot-node-agent"
          ];
        };
      };
    })

    # --------------------------------------------------------------------------- server -----
    (mkIf cfg.enable {
      assertions = [
        {
          # Multiple coexisting servers are allowed since 2026-10-25 (per-host Coroot UIs):
          # each server's LOCAL agent pushes to itself over loopback, and only agentEnable
          # hosts without their own server fall back to the first server in the list.
          assertion = config.MODULES.services.prometheus.enable;
          message = ''
            MODULES.services.coroot.enable is set but MODULES.services.prometheus.enable is not -
            the server bootstraps with this host's Prometheus as its metrics datasource and has
            nothing to query without it.
          '';
        }
      ];

      # Only ClickHouse still runs in a container here (module header); since 2026-10-27 the
      # agent and the server itself are native units and an agent-only host needs no docker.
      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";

      systemd.tmpfiles.rules = [
        "d ${dataDir} 0700 root root - -"
      ];

      # Coroot ships a hardcoded default admin password ("admin"), and CreateAdminIfNotExists
      # consumes AUTH_BOOTSTRAP_ADMIN_PASSWORD at first start only - later restarts keep whatever
      # the UI has. Same lifecycle as omniroute's INITIAL_PASSWORD (audit #9): readable root-only
      # for the first-login window, dropped from disk after a week. Recovery if missed: see
      # `coroot set-admin-password`, or re-add the line and delete the admin user row.
      systemd.services.coroot-secrets = {
        description = "Generate Coroot's bootstrap admin password";
        before = ["coroot.service"];
        requiredBy = ["coroot.service"];
        path = [
          pkgs.openssl
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = ''
          if [ -s ${secretsFile} ]; then
            if grep -q '^AUTH_BOOTSTRAP_ADMIN_PASSWORD=' ${secretsFile} \
               && [ "$(( $(date +%s) - $(stat -c %Y ${secretsFile}) ))" -gt 604800 ]; then
              sed -i '/^AUTH_BOOTSTRAP_ADMIN_PASSWORD=/d' ${secretsFile}
            fi
          else
            echo "AUTH_BOOTSTRAP_ADMIN_PASSWORD=$(openssl rand -hex 16)" > ${secretsFile}
          fi
        '';
      };

      # One-time lift of the docker era's sqlite (+ any other state) into the native data dir,
      # so the 1.9.9 -> 1.27.4 upgrade keeps the admin user, the project and its id. Guarded on
      # the absence of the sqlite file: once the native server has written it, this is a no-op
      # forever and the docker volume is dead weight (module header says how to drop it).
      # 2026-10-27: the guard file is db.sqlite - both 1.9.9 and 1.27 name it that (first
      # deploy guarded on a non-existent coroot.db and re-copied the volume on every boot,
      # which would have reverted the live DB each restart).
      systemd.services.coroot-data-migration = {
        description = "Move Coroot's sqlite data out of the docker volume (one-time)";
        after = ["docker.service"];
        wants = ["docker.service"];
        requiredBy = ["coroot.service"];
        before = ["coroot.service"];
        path = [pkgs.coreutils];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e ${dataDir}/db.sqlite ] && [ -d /var/lib/docker/volumes/coroot-data/_data ]; then
            cp -a /var/lib/docker/volumes/coroot-data/_data/. ${dataDir}/
          fi
        '';
      };

      systemd.services.coroot = {
        description = "Coroot server";
        wantedBy = ["multi-user.target"];
        # ClickHouse takes a few seconds to accept connections; without the ordering the server
        # exits on its first migration attempt and systemd's restart policy recovers it seconds
        # later anyway - this just makes first boot quiet.
        after = ["docker-coroot-clickhouse.service" "coroot-data-migration.service" "coroot-secrets.service"];
        requires = ["docker-coroot-clickhouse.service" "coroot-data-migration.service"];
        serviceConfig = {
          Restart = "always";
          RestartSec = "5s";
          # The bootstrap admin password (consumed on first start only) arrives through the
          # same root-only env file the docker container used; kingpin reads the env name
          # directly, so no ExecStart interpolation and no secret in the unit or argv.
          EnvironmentFile = secretsFile;
          ExecStart = lib.concatStringsSep " " [
            "${pkgs-unstable.coroot}/bin/coroot"
            "run"
            # Bind all interfaces on :PORT: remote hosts' agents push here over tailscale0,
            # and nothing else routes to this box - the firewall's default zone still drops;
            # see the tailscale0 rule below. The UI and the OTLP endpoints live on this port
            # too (Traefik fronts it as coroot.<host>).
            "--listen=:${toString config.PORTS.coroot}"
            "--grpc-disabled"
            "--data-dir=${dataDir}"
            # "global_*" (not "bootstrap_*"): re-applied from config on every start, so a changed
            # PORTS.prometheus after a rebuild actually takes effect instead of living only in the
            # first-run database row.
            "--global-prometheus-url=http://127.0.0.1:${toString config.PORTS.prometheus}"
            # coroot parses the prometheus pair together: a URL without a refresh-interval is
            # fatal at startup (config.go "invalid global_prometheus: invalid refresh-interval"
            # - seen live on akos01 2026-10-25). 15s is the documented default.
            "--global-refresh-interval=15s"
            # 2026-10-26, the alert storm after the native-server switch: UseClickHouse DEFAULTS
            # TO FALSE, and then collector/metrics.go proxies agent remote-write to PROMETHEUS
            # (that's how the old 1.9.9 docker image worked). But 1.27's world/constructor reads
            # the agent series from CLICKHOUSE - with an empty metrics table every app 404s and
            # every check fires at once ("no instances available" x27, network checks blind).
            # Coroot's own deploy manifests run modern servers with CH as the metrics store; so
            # must we. (The agent's /api/v1/write proxy traffic into prometheus stops with this.)
            "--global-prometheus-use-clickhouse"
            "--global-clickhouse-address=127.0.0.1:${toString config.PORTS.corootClickhouseNative}"
            "--do-not-check-for-updates"
          ];
        };
      };

      virtualisation.oci-containers.containers.coroot-clickhouse = {
        image = cfg.clickhouseImage;
        environment.CLICKHOUSE_SKIP_USER_SETUP = "1";
        volumes = [
          # Must sort AFTER the image's own config.d/docker_related_config.xml: ClickHouse
          # merges config.d alphabetically and that file re-listens on all interfaces,
          # which re-exposes 8142/8143 on the host's tailscale IP (Coroot flagged it as
          # "publicly exposed database" on akos01, 2026-10-25). "z-" wins the race.
          "${clickhouseConfig}:/etc/clickhouse-server/config.d/z-coroot.xml:ro"
          "coroot-clickhouse-data:/var/lib/clickhouse"
          "coroot-clickhouse-logs:/var/log/clickhouse-server"
        ];
        extraOptions = [
          "--network=host"
          # The compose file raises nofile for ClickHouse; the XML drop-in has no equivalent.
          "--ulimit=nofile=262144:262144"
        ];
      };

      # Remote agents (other hosts' node-agents) push here.
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [config.PORTS.coroot];

      # Coroot also writes its own derived metrics back into this host's Prometheus
      # (POST /api/v1/write); without the remote-write receiver that endpoint 404s and
      # coroot floods its log with "failed to write: got 404 from prometheus" (seen live
      # on akos01's first coroot boot, 2026-10-25). Idempotent: extraFlags merge as a list
      # option, and a host without coroot keeps its default flag set.
      services.prometheus.extraFlags = ["--web.enable-remote-write-receiver"];

      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.services.coroot = "127.0.0.1:${toString config.PORTS.coroot}";
    })
  ];
}
