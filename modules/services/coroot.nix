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
{
  config,
  lib,
  pkgs,
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

    packageAgent = mkEnableOption ''
      coroot-node-agent as a NATIVE systemd unit from the nixpkgs package instead of the
      docker container. This is the microVM-guest path: the guest has no docker, but it IS
      a kernel of its own (BTF on, nixpkgs default), so the agent reports the VM's services
      as a separate node. For a guest importing only the microvm module (the vm-agents
      prototype), use its inline systemd unit instead - this option needs the fleet module
      set (PORTS, and coroot.nix's paths are validated even inside its own mkIfs).
    '';

    collectorUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://100.92.36.52:8080";
      description = ''
        Override for the agent's server endpoint. Null (the default) derives it: loopback on the
        server host, the server host's Tailscale IP everywhere else.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/coroot/coroot:1.9.9";
      description = "Coroot server image. Pinned release; docker-images-update.service pulls newer tags on its own.";
    };

    agentImage = mkOption {
      type = types.str;
      default = "ghcr.io/coroot/coroot-node-agent:1.19.7";
      description = "Coroot node-agent image. Must stay within a minor version of `image` (the agent/server API is versioned together).";
    };

    clickhouseImage = mkOption {
      type = types.str;
      default = "clickhouse/clickhouse-server:24.3";
      description = "ClickHouse image; the tag Coroot's own docker-compose pins.";
    };
  };

  config = lib.mkMerge [
    # ---------------------------------------------------------------- agent (server or not) --
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

      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";

      virtualisation.oci-containers.containers.coroot-node-agent = {
        image = cfg.agentImage;
        cmd = [
          # Loopback even with host networking: nothing connects TO the agent (it pushes), and the
          # port serves plain /metrics. Default would be the same; named in PORTS anyway.
          "--listen=127.0.0.1:${toString config.PORTS.corootNodeAgent}"
          "--collector-endpoint=${collectorUrl}"
          "--cgroupfs-root=/host/sys/fs/cgroup"
          "--wal-dir=/data"
        ];
        volumes = [
          # Coroot's own compose mounts. tracefs + debugfs for kprobes/uprobes/tc, and the host's
          # cgroup tree at a side path so the agent can still see containers from inside its own.
          "/sys/kernel/tracing:/sys/kernel/tracing"
          "/sys/kernel/debug:/sys/kernel/debug"
          "/sys/fs/cgroup:/host/sys/fs/cgroup"
          "coroot-node-agent-data:/data"
        ];
        # eBPF needs the lot: privileged (CAP_BPF/PERFMON + access to every pid/net namespace),
        # host PID to attribute sockets to the right container, host netns to see the host's and
        # the microVM taps' traffic.
        extraOptions = [
          "--privileged"
          "--pid=host"
          "--network=host"
        ];
      };
    })

    # ------------------------------------------------------ guest agent (microVM path) ------
    # The nixpkgs package (not the image): a firecracker guest has no docker daemon, and
    # pulling an image into a VM that gets its store read-only from the host would be
    # backwards anyway. The guest kernel ships CONFIG_DEBUG_INFO_BTF (nixpkgs
    # common-config since 5.11), which is what the agent's CO-RE eBPF probes need.
    (mkIf cfg.packageAgent {
      assertions = [
        {
          assertion = !(cfg.enable || cfg.agentEnable);
          message = ''
            MODULES.services.coroot.packageAgent and the docker agent cannot both run:
            they would fight over the loopback listener.
          '';
        }
      ];

      systemd.services.coroot-node-agent = {
        description = "Coroot node agent (package build, microVM guest)";
        wantedBy = ["multi-user.target"];
        # Push-only, but the collector lives on the tailnet, so tailscaled must be up first.
        after = ["network-online.target" "tailscaled.service"];
        wants = ["network-online.target"];
        requires = ["tailscaled.service"];
        serviceConfig = {
          Restart = "always";
          RestartSec = "5s";
          # The only writable state is the WAL spool for push retries.
          StateDirectory = "coroot-node-agent";
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.coroot-node-agent}/bin/coroot-node-agent"
            "--listen=127.0.0.1:${toString config.PORTS.corootNodeAgent}"
            "--collector-endpoint=${collectorUrl}"
            # cgroup v2, the guest's own tree - no /host indirection (that's the docker
            # variant's problem: a container cannot see its own host's root cgroup).
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
        before = ["docker-coroot.service"];
        requiredBy = ["docker-coroot.service"];
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

      virtualisation.oci-containers.containers.coroot = {
        image = cfg.image;
        environment = {
          # Reachable by remote agents on the tailscale interface - and nowhere else, the
          # firewall's default zone still drops; see the tailscale0 rule below.
          LISTEN = ":${toString config.PORTS.coroot}";
          # OTLP ingest: the HTTP listener serves /v1/traces, /v1/metrics and /v1/logs on the
          # SAME port, no auth (same trust boundary as the agent push above) - verified with
          # a live python-OTel SDK push on akos01, 2026-10-25. Loopback clients per the
          # per-host coroot model: every host's apps push to their OWN server over 127.0.0.1.
          # NOTE: this image (1.9.9) has NO OTLP/gRPC server (github coroot 1.9.9 has no
          # collector/grpc.go) - newer releases add `GRPC_LISTEN`; revisit when the image
          # is bumped. Emitters configured below therefore use OTLP/HTTP endpoints with
          # the full /v1/<signal> path.
          DATA_DIR = "/data";
          # "global_*" (not "bootstrap_*"): re-applied from config on every start, so a changed
          # PORTS.prometheus after a rebuild actually takes effect instead of living only in the
          # first-run database row.
          GLOBAL_PROMETHEUS_URL = "http://127.0.0.1:${toString config.PORTS.prometheus}";
          # coroot parses these together: GLOBAL_PROMETHEUS_URL without
          # GLOBAL_REFRESH_INTERVAL is fatal at startup (config.go:178 "invalid
          # global_prometheus: invalid refresh-interval") - seen live on akos01
          # 2026-10-25. 15s is the documented default.
          GLOBAL_REFRESH_INTERVAL = "15s";
          GLOBAL_CLICKHOUSE_ADDRESS = "127.0.0.1:${toString config.PORTS.corootClickhouseNative}";
          DISABLE_USAGE_STATISTICS = "true";
        };
        environmentFiles = [secretsFile];
        volumes = ["coroot-data:/data"];
        # The compose file runs it as root; the sqlite DB in the named volume is root-owned.
        extraOptions = ["--network=host" "--user=0:0"];
      };

      # ClickHouse takes a few seconds to accept connections; without the ordering the server
      # exits on its first migration attempt and systemd's restart policy recovers it seconds
      # later anyway - this just makes first boot quiet.
      systemd.services.docker-coroot = {
        after = ["docker-coroot-clickhouse.service"];
        requires = ["docker-coroot-clickhouse.service"];
      };
      systemd.services.docker-coroot-node-agent = {
        after = ["docker-coroot.service"];
        wants = ["docker-coroot.service"];
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
