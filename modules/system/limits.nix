# LIMITS - the resource-limit registry (PLAN.md §1), deliberately mirroring
# modules/networking/ports.nix: one attrset, everything derived and asserted from it.
#
# How it works:
#   - `LIMITS` IS the table: the fleet-wide §1.3 defaults arrive as the option's default value,
#     so a host tunes a single field (LIMITS.ollama.memMax = "12G") and submodule merging keeps
#     the rest of the row. Each row says WHEN it applies here (a predicate over the usual
#     enable options) and WHICH units/container it caps; inactive rows are inert. Predicates,
#     not "does the unit exist" probes, because reading config.systemd.services from a module
#     that WRITES it would recurse - and declaring serviceConfig for units that don't exist
#     here would mint ghost units.
#   - Opt a row out explicitly (a deliberate coverage choice, mirroring PORTS):
#         LIMITS.ollama = lib.mkForce { when = _: false; };
#   - `MODULES.system.limits.memoryBudget` (set per host) turns it into an eval-time assertion:
#     the sum of every ACTIVE row's MemoryMax must fit the machine - "catch drift at eval time,
#     not at 03:00 when OOM kills prometheus".
#   - Docker containers ride under docker.service, so unit-level caps never reach them; rows with
#     a dockerName get the equivalent `--memory`/`--cpus`/`--pids-limit` flags instead (§1.5's
#     slice alternative). `nice` rows get Nice=19 + IOSchedulingClass=idle in place of the bfq
#     IOWeight machinery (§1.6).
#   - §1.5 ollama exception: quota-only (CPU/Tasks), no MemoryMax - a wall below model+KV size
#     doesn't sandbox, it kills inference at 3am.
#   - §1.7 observability (PSI collector, pressure alerts) lives in prometheus.nix / grafana.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkIf mkMerge types;

  cfg = config.MODULES.system.limits;

  rowType = types.submodule {
    options = {
      when = mkOption {
        type = types.nullOr (types.functionTo types.bool);
        default = null;
        description = ''
          Predicate over the host's config deciding whether this row is active here.
          CONTRACT: must be total - never throw. Guard every option read with `or false`
          (builtins.tryEval does NOT catch missing-attribute errors on this nix, and the
          predicate is called while merging this module's config on every host, including
          ones where the inspected module is not imported at all).
        '';
      };
      units = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "systemd units this row caps; all must exist whenever `when` is true.";
      };
      dockerName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OCI container this row caps via --memory/--cpus/--pids-limit instead of unit cgroup options (containers ride under docker.service, unreachable from unit caps).";
      };
      cpuOnly = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Quota only, no memory wall - the §1.5 ollama reasoning (also privileged eBPF agents).";
      };
      tasks = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "TasksMax / --pids-limit. Counts THREADS too, so thread-heavy runtimes need slack.";
      };
      cpu = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "CPUQuota / --cpus.";
      };
      memHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "768M";
        description = "MemoryHigh - the throttle line; reclaim pressure starts here.";
      };
      memMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "MemoryMax / --memory - the wall. Budget-checked when MODULES.system.limits.memoryBudget is set.";
      };
      nice = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Nice=19 + IOSchedulingClass=idle for background-IO services (§1.6).";
      };
      note = mkOption {
        type = types.str;
        default = "";
        description = "Why the row looks the way it does.";
      };
    };
  };

  toBytes = s: let
    m = builtins.match "([0-9]+)([KMG]?)" s;
    mult =
      {
        "" = 1;
        K = 1024;
        M = 1024 * 1024;
        G = 1024 * 1024 * 1024;
      }
    .${
        builtins.elemAt m 1
      };
  in
    assert m != null;
      (builtins.fromJSON (builtins.head m)) * mult;

  # --cpus wants "1.5" where CPUQuota wants "150%".
  cpusFromQuota = q: let
    m = builtins.match "([0-9]+)%" q;
  in
    assert m != null;
      toString ((builtins.fromJSON (builtins.head m)) / 100);

  # §1.3's "boring tier, one default", parameterised by unit + predicate.
  boring = unit: when: {
    inherit when;
    units = [unit];
    tasks = 128;
    cpu = "100%";
    memHigh = "256M";
    memMax = "384M";
  };

  # Small Go binaries that must answer while everything else burns.
  tiny = unit: when: {
    inherit when;
    units = [unit];
    tasks = 16;
    cpu = "10%";
    memHigh = "32M";
    memMax = "64M";
    note = "monitoring must survive everyone else - tiny but guaranteed.";
  };

  # ---------------------------------------------------------------- the §1.3 table ---------
  # One row per unit group; rows never span units with different lifetimes (that would write
  # empty serviceConfig attrs into units absent on some hosts). The n8n / librechat / vllm rows
  # died with those services (2026-10-24).
  table =
    {
      synapse = {
        when = c: (c.services.matrix-synapse.enable or false);
        units = ["matrix-synapse"];
        tasks = 192;
        cpu = "200%";
        memHigh = "1536M";
        memMax = "2G";
        note = "synapse threads heavily.";
      };
      matrixMas = {
        when = c: (c.MODULES.services.matrix.enable or false) && (c.MODULES.services.matrix.mas.enable or false);
        units = ["matrix-mas"];
        tasks = 192;
        cpu = "200%";
        memHigh = "1G";
        memMax = "1536M";
        note = "MAS is python.";
      };
      postgresql = {
        when = c: (c.services.postgresql.enable or false);
        units = ["postgresql"];
        tasks = 96;
        cpu = "200%";
        memHigh = "1G";
        memMax = "1536M";
        note = "96 = 64 backend slots (max_connections pinned to 64 by the assertion below) + bgworkers/autovacuum/threads.";
      };
      litellm = {
        when = c: (c.MODULES.services.litellm.enable or false);
        units = ["litellm"];
        dockerName = "litellm";
        tasks = 256;
        cpu = "150%";
        memHigh = "512M";
        memMax = "768M";
        note = "uvicorn workers, no threads concern.";
      };
      traefik = {
        when = c: (c.services.traefik.enable or false);
        units = ["traefik"];
        tasks = 128;
        cpu = "100%";
        memHigh = "256M";
        memMax = "384M";
      };
      ollama = {
        when = c: (c.MODULES.services.ollama.enable or false);
        units = ["ollama"];
        tasks = 512;
        cpu = "700%";
        cpuOnly = true;
        note = "§1.5 exception: a memory wall below model+KV size doesn't sandbox, it kills inference. Quota only until the catalogue stabilises, then memMax = largest model + 20%.";
      };
      immichServer = {
        when = c: (c.services.immich.enable or false);
        units = ["immich-server"];
        tasks = 256;
        cpu = "200%";
        memHigh = "1G";
        memMax = "1536M";
      };
      immichMl = {
        when = c: (c.services.immich.machine-learning.enable or false);
        units = ["immich-machine-learning"];
        tasks = 256;
        cpu = "200%";
        memHigh = "768M";
        memMax = "1536M";
        note = "ML does not need the moon.";
      };
      redisImmich = boring "redis-immich" (c: (c.services.redis.servers.immich.enable or false));
      redisSearx = boring "redis-searx" (c: (c.services.redis.servers.searx.enable or false));
      grafana = {
        when = c: (c.services.grafana.enable or false);
        units = ["grafana"];
        tasks = 128;
        cpu = "100%";
        memHigh = "384M";
        memMax = "512M";
      };
      prometheus = {
        when = c: (c.services.prometheus.enable or false);
        units = ["prometheus"];
        tasks = 128;
        cpu = "200%";
        memHigh = "1536M";
        memMax = "2G";
        note = "tsdb churns, but the fleet retention doesn't need 3G.";
      };
      loki = {
        when = c: (c.services.loki.enable or false);
        units = ["loki"];
        tasks = 128;
        cpu = "200%";
        memHigh = "1536M";
        memMax = "2G";
      };
      coroot = {
        when = c: (c.MODULES.services.coroot.enable or false);
        units = ["docker-coroot"];
        dockerName = "coroot";
        tasks = 256;
        cpu = "200%";
        memHigh = "768M";
        memMax = "1G";
      };
      corootClickhouse = {
        when = c: (c.MODULES.services.coroot.enable or false);
        units = ["docker-coroot-clickhouse"];
        dockerName = "coroot-clickhouse";
        # tasks >= 512 + slack: ClickHouse's BackgroundSchedulePool asks the global thread
        # pool for exactly its background_schedule_pool_size (512 on 8 vcpu), and aborts
        # with "Couldn't get 512 threads from global thread pool" when --pids-limit caps
        # mid-startup. That abort segfault-looped the container on akos01 for ~40 min
        # (2026-10-25, exit 139 every minute, reproduced in isolation).
        tasks = 1024;
        cpu = "200%";
        memHigh = "1G";
        memMax = "3G";
        note = "ClickHouse caches aggressively; the High line is what keeps it honest. memMax 3G matches the server-wide <max_server_memory_usage> cap in coroot.nix's drop-in.";
      };
      corootNodeAgent = {
        when = c: (c.MODULES.services.coroot.enable or false) || (c.MODULES.services.coroot.agentEnable or false);
        units = ["docker-coroot-node-agent"];
        dockerName = "coroot-node-agent";
        tasks = 128;
        cpu = "50%";
        cpuOnly = true;
        note = "privileged eBPF: capping its memory turns observability into an outage source.";
      };
      omniroute = {
        when = c: (c.MODULES.services.omniroute.enable or false);
        units = ["omniroute"];
        dockerName = "omniroute";
        tasks = 128;
        cpu = "100%";
        memHigh = "384M";
        memMax = "512M";
      };
      trilium = {
        when = c: (c.MODULES.services.trilium.enable or false);
        units = ["trilium"];
        dockerName = "trilium";
        tasks = 128;
        cpu = "100%";
        memHigh = "256M";
        memMax = "384M";
      };
      homepage = boring "homepage-dashboard" (c: (c.services.homepage-dashboard.enable or false));
      searx = boring "searx" (c: (c.services.searx.enable or false));
      sftpgo = {
        when = c: (c.services.sftpgo.enable or false);
        units = ["sftpgo"];
        tasks = 128;
        cpu = "100%";
        memHigh = "256M";
        memMax = "512M";
      };
      transmission = {
        when = c: (c.services.transmission.enable or false);
        units = ["transmission"];
        tasks = 128;
        cpu = "100%";
        memHigh = "256M";
        memMax = "512M";
        nice = true;
        note = "the §1.6 alternative to bfq/IOWeight: idle scheduling instead of fairness weights.";
      };
      syncthing = {
        when = c: (c.services.syncthing.enable or false);
        units = ["syncthing"];
        tasks = 128;
        cpu = "100%";
        memHigh = "512M";
        memMax = "768M";
        nice = true;
        note = "second IO abuser (§1.6); rescan storms must not starve ZFS.";
      };
      hermes = {
        when = c: (c.MODULES.services.hermes-agent.enable or false);
        units = [
          "hermes-agent"
          "hermes-backend"
        ];
        tasks = 256;
        cpu = "100%";
        memHigh = "512M";
        memMax = "768M";
        note = "LLM-directed executors; the existing hermes sandbox is the wall's inner face.";
      };
      paseo = {
        when = c: (c.MODULES.services.paseo.enable or false);
        units = ["paseo-daemon"];
        tasks = 256;
        cpu = "100%";
        memHigh = "512M";
        memMax = "768M";
      };
      paseoHermes = {
        when = c: (c.MODULES.services.paseo-hermes.enable or false);
        units = ["paseo-hermes"];
        tasks = 256;
        cpu = "100%";
        memHigh = "512M";
        memMax = "768M";
      };
      vaultwarden = {
        when = c: (c.services.vaultwarden.enable or false);
        units = ["vaultwarden"];
        tasks = 64;
        cpu = "100%";
        memHigh = "128M";
        memMax = "256M";
      };
      fastdds = {
        when = c: (c.MODULES.services.fastdds.enable or false);
        units = ["docker-fastdds_discovery"];
        dockerName = "fastdds_discovery";
        tasks = 64;
        cpu = "50%";
        memHigh = "128M";
        memMax = "256M";
      };
      dnsmasq = {
        when = c: (c.services.dnsmasq.enable or false);
        units = ["dnsmasq"];
        tasks = 16;
        cpu = "25%";
        memHigh = "32M";
        memMax = "64M";
      };
      firefly = {
        when = c: (c.services.firefly-iii.enable or false);
        units = [
          "phpfpm-firefly-iii"
          "firefly-iii-cron"
        ];
        tasks = 128;
        cpu = "100%";
        memHigh = "384M";
        memMax = "512M";
      };
      nginx = boring "nginx" (c: (c.services.nginx.enable or false));
      smartd = tiny "smartd" (c: (c.services.smartd.enable or false));
    }
    // lib.genAttrs [
      "mautrix-whatsapp"
      "mautrix-signal"
      "mautrix-slack"
      "mautrix-discord"
      "mautrix-mattermost"
      "mautrix-jabber"
    ] (
      n: {
        when = c: (c.services.${n}.enable or false);
        units = [n];
        tasks = 64;
        cpu = "50%";
        memHigh = "192M";
        memMax = "256M";
        note = "one go process per bridge.";
      }
    )
    // {
      exportersNode = tiny "prometheus-node-exporter" (c: (c.services.prometheus.exporters.node.enable or false));
      exportersZfs = tiny "prometheus-zfs-exporter" (c: (c.services.prometheus.exporters.zfs.enable or false));
      exportersTailscale = tiny "prometheus-tailscale-exporter" (c: (c.services.prometheus.exporters.tailscale.enable or false));
      exportersNginx = tiny "prometheus-nginx-exporter" (c: (c.services.prometheus.exporters.nginx.enable or false));
      exportersPhpFpm = tiny "prometheus-php-fpm-exporter" (c: (c.services.prometheus.exporters.php-fpm.enable or false));
      exportersPostgres = tiny "prometheus-postgres-exporter" (c: (c.services.prometheus.exporters.postgres.enable or false));
    };

  # FIELD-WISE row merge. Why not `default = table` on the option: on nixpkgs 26.05 the
  # moment a host defines ANY dotted key under an attrsOf option (LIMITS.ollama.memMax),
  # the option's default MAP is dropped entirely - the table vanishes and every row whose
  # instance the host did not name disappears from config.LIMITS (verified empirically,
  # same landmine as modules/security/jail.nix). So the option defaults to {} and every
  # consumer reads rows through this merge: table row overlaid by the non-default (non-
  # null / non-"" ) fields the host wrote. Unit-KEY generation still reads the raw static
  # table so no config value ever decides which options this module defines.
  # mirrors every rowType field's post-submodule default, so merged rows always have the
  # full key set even when a table entry elides a field.
  rowDefaults = {
    units = [];
    cpuOnly = false;
    nice = false;
    note = "";
    dockerName = null;
    tasks = null;
    cpu = null;
    memHigh = null;
    memMax = null;
  };
  effectiveRow = name: let
    merged =
      rowDefaults
      // (table.${name} or {})
      // lib.filterAttrs (
        _: v: v != null && v != ""
      ) (config.LIMITS.${name} or {});
  in
    merged
    // {
      when = merged.when or (_: false);
    };
in {
  options = {
    LIMITS = mkOption {
      type = types.attrsOf rowType;
      default = {};
      example = {
        ollama.memMax = "12G";
      };
      description = ''
        The per-service resource-limit registry (see modules/system/limits.nix for the
        table). The fleet table is the module's own data, NOT this option's default -
        hosts write field overrides here (`LIMITS.ollama.memMax = "12G";`) and the module
        merges them field-wise (see effectiveRow); retire a row with
        `LIMITS.<name> = { when = _: false; };`.
      '';
    };

    MODULES.system.limits = {
      memoryBudget = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "18G";
        description = ''
          When set, eval fails unless the sum of every active LIMITS row's memHigh fits this
          budget. memHigh (the throttle line) and not memMax (the wall) is what this sums,
          because the plan's own §1.3 table breaks a Σ-memMax check on paper: walls are
          allowed to oversubscribe, expected-settling-points are not. The plan's "catch drift
          at eval time, not at 03:00". Null disables (variable-workload desktops).
        '';
      };

      managePressureRules = mkOption {
        type = types.bool;
        default = false;
        description = ''
          §1.7: write the PSI-pressure alerting rules into the Prometheus rules directory
          (/var/lib/prometheus-rules, Syncthing-synced fleet-wide). Enable on exactly one host -
          the one whose Prometheus is the hub - so the file is authored once and syncs outward;
          every host's node-exporter publishes the pressure metrics regardless (the "pressure"
          collector is enabled in prometheus.nix). The Grafana/Alertmanager side consumes them.
        '';
      };
    };
  };

  config = mkMerge [
    # ---- systemd units ----------------------------------------------------------------
    # Generated keys come from the STATIC table, and the mkIf flag sits ON the attrsOf option
    # (`systemd.services = mkIf active { ${u} = ...; }`) - not on the instance or a leaf
    # field: any nested definition (even mkIf-false at the leaf) marks the instance key as
    # declared, which on hosts lacking the unit produces a ghost unit file, and for
    # oci-containers a phantom instance that dies on the required `image`. Flag-at-attrsOf
    # keeps the hidden keys out of the collection walk entirely; the condition itself is
    # total-by-contract (see the when description) and never looked at unless the option is
    # merged. The condition may read config freely (keys can't - collecting this module's
    # attrNames would force the guards through the services attr = unfalsifiable loop).
    (mkMerge (lib.mapAttrsToList (
        name: row:
          mkMerge (map (u:
            mkIf ((effectiveRow name).when config) {
              systemd.services = {
                ${u}.serviceConfig = let
                  r = effectiveRow name;
                in
                  {
                    TasksMax = r.tasks or null;
                    CPUQuota = r.cpu or null;
                    MemoryHigh = r.memHigh or null;
                    MemoryMax = r.memMax or null;
                    # The wall only exists if swap cannot absorb it (zram hosts would OOM-panic
                    # instead of thrash otherwise).
                    MemorySwapMax =
                      if (r.memMax or null) != null
                      then 0
                      else null;
                  }
                  // lib.optionalAttrs (r.nice or false) {
                    Nice = 19;
                    IOSchedulingClass = "idle";
                  };
              };
            })
          row.units or [])
      )
      table))

    # ---- docker flags (unit caps never reach containers under docker.service) ---------
    (mkMerge (lib.mapAttrsToList (
      name: row:
        mkIf ((row.dockerName or null) != null) {
          virtualisation.oci-containers.containers = mkIf ((effectiveRow name).when config) {
            ${row.dockerName}.extraOptions = let
              r = effectiveRow name;
            in
              (lib.optionals (r.cpu or null != null) ["--cpus=${cpusFromQuota r.cpu}"])
              ++ (lib.optionals (r.tasks or null != null) ["--pids-limit=${toString r.tasks}"])
              ++ lib.optionals (! (r.cpuOnly or false) && (r.memMax or null) != null) [
                "--memory=${r.memMax}"
                # --memory-swap is an absolute total, not an addition: equal to --memory is
                # the container form of MemorySwapMax=0.
                "--memory-swap=${r.memMax}"
              ];
          };
        }
    ) (lib.filterAttrs (_: r: (r.dockerName or null) != null) table)))

    # ---- assertions + postgres connection budget ---------------------------------------
    {
      # §1.4, decided deliberately: systemd-oomd OFF. (The plan assumed it was the NixOS
      # default-off; in 26.05 it is actually default-ON, so this is a real decision, not a
      # no-op: oomd would fight MemoryMax semantics and can kill ollama mid-inference when a
      # model load legitimately spikes PSI pressure. The kernel cgroup wall is the
      # enforcement; revisit with swapUsedTarget-only (UserSwapOut off) once these limits
      # have run clean for a week.)
      systemd.oomd.enable = lib.mkForce false;

      assertions = let
        rowKeys = builtins.attrNames (table // config.LIMITS);
        effective = lib.listToAttrs (
          map (n: {
            name = n;
            value = effectiveRow n;
          })
          rowKeys
        );
        activeRows' = lib.filterAttrs (_: e: e.when config) effective;
        appliedUnits' = builtins.concatMap (e: e.units) (builtins.attrValues activeRows');
      in
        lib.mapAttrsToList (name: e: {
          assertion = e.memHigh == null || e.memMax == null || toBytes e.memHigh < toBytes e.memMax;
          message = "LIMITS.${name}: memHigh (${e.memHigh}) must be below memMax (${e.memMax}).";
        })
        effective
        ++ lib.singleton {
          assertion = (lib.length (lib.unique appliedUnits')) == (lib.length appliedUnits');
          message = "Two LIMITS rows cap the same systemd unit - pick one owner.";
        }
        ++ lib.optional (cfg.memoryBudget != null) {
          assertion =
            builtins.foldl' (acc: e:
              acc
              + (
                if e.memHigh == null
                then 0
                else toBytes e.memHigh
              ))
            0 (builtins.attrValues activeRows')
            <= toBytes cfg.memoryBudget;
          message = "Active LIMITS rows' MemoryHigh throttle lines sum above MODULES.system.limits.memoryBudget (${cfg.memoryBudget}): ${lib.concatStringsSep ", " (lib.mapAttrsToList (n: e: "${n}=${toString e.memHigh}") activeRows')}";
        }
        # A LIMITS key the static key-generation never heard of would silently do nothing.
        ++ lib.mapAttrsToList (n: _: {
          assertion = table ? ${n};
          message = "LIMITS.${n} does not match any row of the built-in table (modules/system/limits.nix) - it would be accepted but applied to nothing; add it to the table instead.";
        })
        (removeAttrs config.LIMITS (builtins.attrNames table));

      # TasksMax on postgres only holds if the connection count holds with it; nixpkgs'
      # default max_connections (100) exceeds the 64-backend budget the postgresql row gives.
      services.postgresql.settings.max_connections = mkIf config.services.postgresql.enable (lib.mkOptionDefault 64);
    }

    # ---- §1.7 pressure rules (authored once, synced to every host's Prometheus) --------
    (mkIf cfg.managePressureRules {
      # The rules directory is a Syncthing folder shared across the Prometheus hosts
      # (prometheus.nix), so authoring here reaches all of them; the reload path unit fires on
      # the file appearing/changing.
      systemd.services.limits-pressure-rules = {
        description = "Write PSI-pressure alerting rules into the Prometheus rules dir";
        after = ["syncthing.service"];
        wants = ["syncthing.service"];
        wantedBy = ["multi-user.target"];
        path = [pkgs.coreutils];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.services.syncthing.user;
          Group = config.services.syncthing.group;
        };
        script = let
          pressure = short: {
            alert = "${short}PressureSustained";
            expr = "rate(node_pressure_${short}_waiting_seconds_total[1m]) > 0.15";
            for = "5m";
            labels = {
              severity = "warning";
            };
            annotations = {
              summary = "{{ $labels.instance }}: sustained ${short} PSI pressure";
              description = ''
                The kernel has spent >15% of every second (PSI stall fraction) waiting on
                ${short} for 5 minutes. The LIMITS cgroup caps put the throttle inside the
                offender; this alert names the machine, the cgroup/Coroot view names the
                service (PLAN.md §1.7).
              '';
            };
          };
          yaml = (lib.generators.toYAML {}) {
            groups = [
              {
                name = "limits-pressure";
                rules = map pressure [
                  "memory"
                  "cpu"
                  "io"
                ];
              }
            ];
          };
        in ''
          mkdir -p ${config.MODULES.services.prometheus.rulesDir}
          cat > ${config.MODULES.services.prometheus.rulesDir}/limits-pressure.yml <<'EOF'
          ${yaml}
          EOF
        '';
      };
    })
  ];
}
