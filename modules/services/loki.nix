# Loki + Grafana Alloy - the fleet's log spine, and the composition point every other
# log-producing module hangs off:
#
#   * journald of this host rides Alloy -> the LOCAL Loki (job=systemd-journal);
#   * modules contribute tailing/parsing pipelines through
#     MODULES.services.loki.extraAlloyBlocks (the sshClient.blocks pattern: this module is
#     the single writer of /etc/alloy/config.alloy, contributors just append River blocks);
#   * contributed streams are written to `loki.write.fleet`, which pushes every URL in
#     MODULES.services.loki.fleetPushTargets. On the aggregator (hp) that list is empty,
#     which resolves to the local Loki; on a tap/edge host (akos01) it mirrors to hp AND
#     keeps a local copy. Grafana's "Loki (fleet)" datasource (MODULES.services.loki
#     .fleetQueryUrl) is what the IDS/edge dashboards query, so every Grafana in the fleet
#     shows the same IDS and public-edge picture regardless of which host wrote the line.
#
# Cardinality contract for contributors: Loki LABELS stay low-cardinality (event_type,
# signature, country, router...); anything unbounded (client IPs, URIs, full user-agents)
# must live in the log line and be extracted at query time with `| json`.
{
  config,
  lib,
  nixosConfigurations ? {},
  configName ? "",
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types concatStringsSep;

  cfg = config.MODULES.services.loki;
  dataDir = config.services.loki.dataDir;
  p = config.PORTS;

  # ---- fleet push topology (2026-11-14, audit finding #6) ------------------------------
  # Loki runs with auth_enabled=false (single-node, filesystem storage): whoever can
  # reach the HTTP port can READ every stream and WRITE any labels. Before this,
  # acceptFleetPush opened 8031 on tailscale0 to the WHOLE 100.64.0.0/10, so one
  # compromised tailnet node (a phone, a future guest, anything) could exfiltrate the
  # journald spine or forge the stream labels the IDS dashboards and SG logic key on.
  # The port now opens ONLY to the declared pushers: hosts whose own
  # MODULES.services.loki.fleetPushTargets name this aggregator, resolved from the
  # flake's nixosConfigurations (the cross-host-facts doctrine, cf. amp.nix /
  # modules/services/coroot.nix). fleetPushFrom overrides the derivation.
  myHostIP = config.MODULES.networking.tailscale.hostIP or null;
  # The addresses a push URL may use to name this host: the tailnet IP (what
  # fleetPushTargets actually spell today) and the MagicDNS short name. Both the
  # "http://<addr>:<port>/..." and the portless "http://<addr>/..." shapes count.
  myAddrs = lib.filter (a: a != null && a != "") [myHostIP config.networking.hostName];
  pointsHere = url: lib.any (a: lib.hasInfix "://${a}:" url || lib.hasInfix "://${a}/" url) myAddrs;

  # Other flake hosts that push their fleet streams INTO this Loki.
  derivedFleetPushSources = lib.unique (
    lib.filter (ip: ip != null && ip != "") (
      lib.flatten (
        lib.mapAttrsToList (
          h: hc:
            lib.optionals
            (h != configName && lib.any pointsHere (hc.config.MODULES.services.loki.fleetPushTargets or []))
            [hc.config.MODULES.networking.tailscale.hostIP or null]
        )
        nixosConfigurations
      )
    )
  );

  isV4 = s: builtins.match "[0-9]+(\\.[0-9]+){3}" s != null;
  # iptables/ip6tables -s accepts only addresses/CIDRs; catch typos at eval time, not
  # at the next switch (the firewall script would abort the activation). The v6 arm
  # demands a ':' so hex-looking host names ("cafe") cannot slip through.
  isAddrOrCidr = s: builtins.match "([0-9]+(\\.[0-9]+){3}(/[0-9]{1,2})?|[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?)" s != null;
  # The aggregators THIS host dials, as IPv4 literals pulled from its own
  # fleetPushTargets. MicroVM guests see nixosConfigurations={} (AGENTS Rule 2), so
  # unlike the pusher derivation this side never needs the flake - the URL carries
  # the address. MagicDNS names are skipped: they cannot become suricata CIDRs.
  fleetAggregators = lib.unique (
    builtins.filter (s: isV4 s && s != "127.0.0.1") (
      map (
        url: let
          m = builtins.match "https?://([^/:]+).*" url;
        in
          if m == null
          then ""
          else builtins.head m
      )
      cfg.fleetPushTargets
    )
  );

  # Alloy runs as a DynamicUser; the fleet log files it tails must be readable by "other".
  localPushUrl = "http://127.0.0.1:${toString p.loki}/loki/api/v1/push";
  fleetUrls =
    if cfg.fleetPushTargets == []
    then [localPushUrl]
    else cfg.fleetPushTargets;
in {
  options.MODULES.services.loki = {
    enable = mkEnableOption ''
      Loki log aggregation. Comes with a local Grafana Alloy agent that tails this host's own
      systemd journal and pushes it to Loki - promtail (the traditional agent for this) has been
      removed upstream as end-of-life, Alloy is its official replacement.
    '';

    extraAlloyBlocks = mkOption {
      type = types.listOf types.str;
      default = [];
      apply = map lib.trim;
      description = ''
        River config blocks appended, in order, to the generated /etc/alloy/config.alloy -
        the sshClient.blocks doctrine for the Alloy spine: this module is the only writer
        of the file, others contribute source/pipeline blocks. Blocks may reference
        `loki.write.local` and `loki.write.fleet`, which this module always defines. The
        whole file (and thus these blocks) only exists while this module is enabled.
      '';
    };

    fleetPushTargets = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["http://100.92.36.52:8031/loki/api/v1/push"];
      description = ''
        Loki push URLs the FLEET streams (everything written via loki.write.fleet - IDS,
        public-edge) are shipped to, over the tailnet. Empty means "this host is the
        aggregator": the fleet writer falls back to the local Loki. The receiving hosts
        need MODULES.services.loki.acceptFleetPush. 2026-11-14, audit #6: naming an
        aggregator HERE is also the push declaration - the aggregator derives its
        firewall/service-graph allow-list from exactly this option, so a host that
        points its fleetPushTargets at it is automatically an admitted pusher.
      '';
    };

    acceptFleetPush = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Accept fleet log pushes from tailnet peers: binds Loki's HTTP listener to all
        interfaces, but the firewall opens the port ONLY to the declared pushers
        (MODULES.services.loki.fleetPushSources - derived from the fleet's
        fleetPushTargets, cf. audit #6) and keeps loopback working for the local
        Alloy/Grafana. Without this flag Loki binds loopback and is unreachable from
        any peer.
      '';
    };

    fleetPushFrom = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = ["100.83.255.5" "100.99.0.11"];
      description = ''
        Explicit source allow-list for the fleet push port, REPLACING the
        fleetPushTargets-derived list entirely (audit #6) - set it only when the
        derivation cannot see a pusher, and restate the derived members alongside the
        new ones (listing only a guest IP would silently lock out every derived
        pusher). IPv4 addresses or CIDRs only; v6 entries are ignored on hosts with
        networking.enableIPv6 = false. The case the derivation cannot see is a microVM
        guest: guests deliberately see nixosConfigurations = {} (AGENTS Rule 2), so
        their tailnet IP must be appended HERE on the aggregator, with the mandatory
        duplication comment at the site. The empty list means "no peer may push"
        (fail closed).
      '';
    };

    fleetPushSources = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default =
        if cfg.fleetPushFrom != null
        then cfg.fleetPushFrom
        else derivedFleetPushSources;
      description = ''
        The EFFECTIVE pusher source list for this host's Loki: MODULES.services.loki.fleetPushFrom
        when set, else every flake host (and only hosts) whose own fleetPushTargets
        name this host. Read by the firewall rule above and by the service-graph
        `loki-ingest` edge, so the two can never disagree (single derivation).
      '';
    };

    fleetAggregators = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = fleetAggregators;
      description = ''
        The IPv4 literals THIS host dials as fleet push targets, extracted from its own
        fleetPushTargets (loopback excluded: it is the local writer, not a peer). The
        service-graph uses this for the `loki-fleet-push` outbound observation: the tap
        on a pushing host sees its own SYNs to the aggregator, and an undeclared egress
        is SG-DRIFT just as much as undeclared ingress (immich precedent, 2026-10-27).
        Derived from URLs, so microVM guests see it too - the push side never needs
        nixosConfigurations.
      '';
    };

    fleetQueryUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString p.loki}";
      example = "http://100.92.36.52:8031";
      description = ''
        Base URL of the Loki that holds the fleet streams (where fleetPushTargets land).
        Provisioned into Grafana as the "Loki (fleet)" datasource the IDS/edge dashboards
        pin; on the aggregator host the default loopback URL is already correct.
        2026-11-14, audit #6: a REMOTE fleetQueryUrl is also inbound Loki traffic - the
        Grafana datasource read lands on the aggregator's push port, so only hosts that
        ALSO push (or are added to the aggregator's fleetPushFrom) may query a remote
        fleet Loki; today's remote reader, akos01's Grafana, is covered by its own
        fleetPushTargets. A new query-only host will show up as connection refused on
        the datasource, not as a silent gap.
      '';
    };
    geoipDatabase = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/geoip/GeoLite2-Country.mmdb";
      description = ''
        Path to a MaxMind mmdb (city/country/asn) used by the Traefik edge pipeline
        (modules/networking/traefik.nix) to resolve a client's country when Cloudflare's
        CF-IPCountry header is absent - i.e. Funnel and direct-tailnet traffic. Public
        Cloudflare requests get their country from the header with no database at all, so
        the default (null = skip geo resolution) keeps the public analytics complete.
        The file must exist and be readable by alloy when set; it is not fetched.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;

          server = {
            http_listen_address =
              if cfg.acceptFleetPush
              then "0.0.0.0"
              else "127.0.0.1";
            http_listen_port = p.loki;
            # Ring traffic (querier->scheduler/ingester) is process-internal in target=all;
            # bind it to loopback too (it defaulted to 0.0.0.0:9095 - see the common.instance_addr
            # note below for why anything else self-DoSes loki under the fleet's jails).
            grpc_listen_address = "127.0.0.1";
            grpc_listen_port = p.lokiGrpc;
          };

          common = {
            path_prefix = dataDir;
            replication_factor = 1;
            # 2026-10-26, coroot incident anivwpvh: loki auto-detects its ring instance address
            # from the first non-loopback interface = ens18's LAN IP, and dials its OWN
            # scheduler/ingester there. The §3.4 egress jail (modules/security/jail.nix) rightly
            # REJECTs loki dialling the LAN - so target=all rejected itself and every query
            # 500'd (100% availability burn on both hosts). Advertising loopback makes the
            # self-dial a loopback hop (the one thing the jail must allow; see the loki row's
            # allowedLoopbackTCPPorts) instead of a lateral one. This stays loopback even when
            # acceptFleetPush rebinds the HTTP listener: the ring never leaves 127.0.0.1.
            instance_addr = "127.0.0.1";
            storage.filesystem = {
              chunks_directory = "${dataDir}/chunks";
              rules_directory = "${dataDir}/rules";
            };
            ring.kvstore.store = "inmemory";
          };

          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];

          limits_config.retention_period = "30d";
          # 2026-11-12: the previous out_of_order_time_window is not a Loki
          # config field (the real config validator rejected the whole build).
          # Keep Loki's supported unordered ingestion and its default window;
          # increasing max_chunk_age to widen it also changes memory pressure.
          limits_config.unordered_writes = true;

          compactor = {
            working_directory = "${dataDir}/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
        };
      };

      # Remote fleet pushes arrive over tailscale0 only, AND only from the declared
      # pushers (2026-11-14, audit finding #6): Loki is auth_enabled=false, so the old
      # blanket tailscale0 accept of p.loki handed the FULL read+write API to every
      # tailnet node - any compromised peer could exfiltrate the journald spine and
      # forge the stream labels the IDS dashboards/SG logic key on. The accept lines
      # live in extraCommands because the per-interface allowedTCPPorts option cannot
      # express a source match; the firewall script flushes nixos-fw before running
      # them (idempotent, the tuvpn/microvm-host precedent) and they land just before
      # the final log-refuse, so an unlisted source hits the default deny. Loopback is
      # blanket-accepted earlier in the same script (`-A nixos-fw -i lo -j
      # nixos-fw-accept`, verified on hp), so the local Alloy/Grafana keep working
      # regardless of this list. The service-graph `loki-ingest` edge reads the SAME
      # MODULES.services.loki.fleetPushSources - the filter and the IDS cannot diverge.
      # v6 sources only render on IPv6 hosts (networking.enableIPv6 = false means the
      # start script never CREATES ip6tables nixos-fw chains - a bare `ip6tables -A`
      # there aborts the whole activation; the jail.nix family-gating precedent).
      networking.firewall.extraCommands = lib.concatStringsSep "\n" (
        lib.optionals cfg.acceptFleetPush (map (src: ''
            ${
              if lib.hasInfix ":" src
              then "ip6tables"
              else "iptables"
            } -w -A nixos-fw -i tailscale0 -s ${src} -p tcp --dport ${toString p.loki} -j nixos-fw-accept
          '')
          (lib.filter (src: !lib.hasInfix ":" src || config.networking.enableIPv6)
            cfg.fleetPushSources))
      );

      # iptables -s only takes addresses/CIDRs: a MagicDNS name or typo here would
      # abort the whole firewall script at activation. Fail at eval instead.
      assertions = lib.optionals cfg.acceptFleetPush [
        {
          assertion = lib.all isAddrOrCidr cfg.fleetPushSources;
          message = ''
            MODULES.services.loki.fleetPushSources must be plain IPv4/IPv6 addresses
            or CIDRs (got: ${toString cfg.fleetPushSources}). The list is derived from
            other hosts' MODULES.services.loki.fleetPushTargets + tailscale.hostIP, or
            set explicitly via MODULES.services.loki.fleetPushFrom; host names are not
            usable by iptables -s.
          '';
        }
      ];

      # Local agent: reads this host's own journald and pushes it to the Loki instance above,
      # plus the composable `fleet` writer every contributor's blocks forward to.
      # Alloy's NixOS module already grants its service the "systemd-journal" supplementary
      # group, so no extra permission wiring is needed here to read the journal.
      services.alloy.enable = true;
      # Pin the HTTP listen address to PORTS.alloy: Alloy exposes every metric the
      # contributed pipelines mint (stage.metrics on the Suricata EVE tail) on /metrics
      # there, and the prometheus scrape job below reads the same PORTS key.
      services.alloy.extraFlags = ["--server.http.listen-addr=127.0.0.1:${toString p.alloy}"];
      environment.etc."alloy/config.alloy".text = ''
          loki.relabel "journal" {
            forward_to = []

            rule {
              source_labels = ["__journal__systemd_unit"]
              target_label  = "unit"
            }

            // Kernel records carry no _SYSTEMD_UNIT, so they'd land label-less on `unit` and
            // the sg-seen drift query ({unit="kernel"} |= "sg-seen") would find nothing.
            // Keep the _KERNEL field one hop longer; loki.process below turns it into
            // unit="kernel" and drops it again.
            rule {
              source_labels = ["__journal__kernel"]
              target_label  = "kernel_field"
            }

            rule {
              source_labels = ["__journal_priority_keyword"]
              target_label  = "level"
            }
          }

          // loki.source.journal drops the __journal_* internals before forwarding, so the
          // stream labels are exactly the ones this spine mints; label_keep pins that set so
          // a future field addition (or the component's auto job label churn) can't explode
          // the index. Measured 2026-11-11 while wiring the IDS dashboards.
          loki.process "journal" {
            forward_to = [loki.write.local.receiver]

            stage.match {
              selector = "{kernel_field=\"kernel\"}"
              stage.static_labels {
                values = { unit = "kernel" }
              }
            }

            stage.label_keep {
              values = ["job", "host", "unit", "level"]
            }
          }

          loki.source.journal "read" {
            forward_to    = [loki.process.journal.receiver]
            relabel_rules = loki.relabel.journal.rules
            // Persisted read cursor: without it every Alloy restart re-reads from "now" and
            // the journal gap during a restart is lost.
            path          = "/var/lib/alloy/positions-journal.yml"
            labels        = {
              job  = "systemd-journal",
              host = "${config.networking.hostName}",
            }
          }

          loki.write "local" {
            endpoint {
              url = "${localPushUrl}"
            }
          }

          // Fleet streams (IDS, public edge): pushed to MODULES.services.loki.fleetPushTargets,
          // which defaults to the local Loki on the aggregator. Contributors forward here; the
          // journal spine above deliberately stays local-only (volume, and per-host noise has
          // no fleet query value).
          loki.write "fleet" {
          ${concatStringsSep "\n" (map (url: ''
          endpoint {
            url = "${url}"
          }'')
        fleetUrls)}
          }
        ${concatStringsSep "\n\n" cfg.extraAlloyBlocks}
      '';

      # Alloy's own /metrics: the suricata_* and edge_* series the contributed pipelines
      # mint (stage.metrics) are exposed here and scraped by the local Prometheus.
      services.prometheus.scrapeConfigs = lib.optionals config.MODULES.services.prometheus.enable [
        {
          job_name = "alloy";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString p.alloy}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.services.grafana.enable) {
      services.grafana.provision.datasources.settings.datasources = [
        {
          name = "Loki";
          type = "loki";
          # The pinned uid is load-bearing: provisioned datasources update IN PLACE only
          # when the uid matches, and the synced hand-built dashboards reference "loki" by
          # name. A silent re-key here once orphaned the old row (two "Loki" datasources).
          uid = "loki";
          access = "proxy";
          url = "http://127.0.0.1:${toString p.loki}";
        }
        # The cross-host view: every Grafana queries the SAME Loki for the IDS/edge
        # streams (the push targets above decide which Loki that is), so the provisioned
        # fleet dashboards show both hosts' taps from either machine.
        {
          name = "Loki (fleet)";
          type = "loki";
          uid = "loki-fleet";
          access = "proxy";
          url = cfg.fleetQueryUrl;
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.networking.traefik.enable) {
      MODULES.networking.traefik.services.loki = "127.0.0.1:${toString p.loki}";
    })
  ];
}
