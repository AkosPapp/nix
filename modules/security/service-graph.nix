# PLAN.md §7 decision (2026-10-24 review): a SERVICE GRAPH for east-west traffic, enforced
# by the packet filter and OBSERVED by a passive IDS. One module, two halves, so a host
# can run either:
#
#   * The filter uses a dedicated nftables inet table at INPUT priority 10, after
#     iptables' filter hook. A Tailscale/NetBird ACCEPT cannot skip this later hook
#     (verified 2026-11-12: ts-input preceded SG-INPUT on akos01). The table is
#     replaced atomically and never flushes another owner's rules. Do NOT enable
#     networking.nftables: the legacy firewall still owns the UID egress chains.
#     Observe mode logs; enforce mode rejects undeclared TCP and drops undeclared
#     UDP. Established replies and ICMP keep working. NetBird is outbound-only
#     by default: its own blanket INPUT accept is not a host security boundary.
#   * The Suricata half is DETECTION ONLY (af-packet mirror on the tap interface, never
#     a queue/bridge in the path). Its pass-list is GENERATED from the same edge table,
#     so the IDS and the filter cannot disagree; everything else's SYN alerts
#     (`SG-DRIFT`). EVE JSON is tailed as STRUCTURED STREAMS by Alloy (modules/services
#     /loki.nix fleet writer): labels event_type/in_iface/sid/action, src/dst in the line,
#     so Grafana's provisioned "Network IDS" dashboard (and Coroot, which shares this
#     host's Prometheus) see the same picture from either tap host. Engine stats leave via
#     a suricatasc -> node_exporter textfile timer (suricata_* series). On a host without
#     Loki the old journald tail remains as fallback shipping.
#     `suricata.edge` additionally taps `lo` (bpf-scoped to Traefik's PUBLIC entry-point
#     ports): Cloudflare terminates the public clients' TLS at its edge, so loopback is
#     the ONE place this box sees public requests as parseable cleartext HTTP - real
#     DPI (EVE http/tls events + the local EDGE-* signatures, still auditable in-git).
#     No remote rulesets are fetched - the local edge rules are the entire set, which
#     keeps the whole detection story auditable in-git.
#
# Deliberate scope limits: TCP on the tap interfaces only. Loopback east-west is the
# jails' jurisdiction (egress chains + loopback allow-lists already exist there); UDP
# stays with the existing firewall (tailscale's own transport, DNS, syncthing discovery -
# logging every QUIC burst would drown the drift signal); public-side ingress is
# traefik/cloudflared's business, not east-west.
{
  config,
  lib,
  pkgs,
  nixosConfigurations ? {},
  configName ? "",
  ...
}: let
  inherit (lib) mkOption mkIf mkMerge types concatStringsSep;

  cfg = config.MODULES.security.serviceGraph;

  # Tailscale CGNAT + MagicDNS ULA: "anyone on the tailnet" (humans, admin tooling).
  tailnet4 = "100.64.0.0/10";
  tailnet6 = "fd7a:115c:a1e0::/48";
  isV6 = s: lib.hasInfix ":" s;

  # Fleet peer addresses, from the flake's own configs (specialArgs).
  peerIPs = lib.unique (
    lib.filter (ip: ip != null && ip != "") (
      lib.flatten (
        lib.mapAttrsToList (
          h: hc: lib.optional (h != configName) (hc.config.MODULES.networking.tailscale.hostIP or null)
        )
        nixosConfigurations
      )
    )
  );
  # Hosts whose Prometheus scrapes us (the hub set; each host's own IP is not a "peer").
  scrapeSources = lib.unique (
    lib.filter (ip: ip != null && ip != "") (
      lib.flatten (
        lib.mapAttrsToList (
          h: hc:
            lib.optionals
            (h != configName && hc.config.services.prometheus.enable or false)
            [hc.config.MODULES.networking.tailscale.hostIP]
        )
        nixosConfigurations
      )
    )
  );
  # Hosts running the immich SERVER, which dial every fleet immich-machine-learning worker
  # over the tailnet - modules/services/immich.nix builds that failover chain from the flake,
  # so the dials are sanctioned traffic and must be declared here too (measured on hp
  # 2026-10-27: akos01's server dials hp:3003; undeclared, suricata fired SG-DRIFT on every
  # SYN and coroot painted immich with RTT/connectivity alerts).
  immichServerSources = lib.unique (
    lib.filter (ip: ip != null && ip != "") (
      lib.flatten (
        lib.mapAttrsToList (
          h: hc:
            lib.optionals
            (h != configName && hc.config.MODULES.services.immich.enable or false)
            [hc.config.MODULES.networking.tailscale.hostIP]
        )
        nixosConfigurations
      )
    )
  );
  # Mirror of the above: the remote workers THIS host's immich server dials (the same
  # MODULES.services.immich.machineLearning.enable predicate immich.nix uses to build its
  # urls chain; the local worker is loopback and out of the tap's scope).
  immichRemoteMlSources = lib.unique (
    lib.filter (ip: ip != null && ip != "") (
      lib.flatten (
        lib.mapAttrsToList (
          h: hc:
            lib.optionals
            (h != configName && hc.config.MODULES.services.immich.machineLearning.enable or false)
            [hc.config.MODULES.networking.tailscale.hostIP]
        )
        nixosConfigurations
      )
    )
  );

  # ---- the edge table ---------------------------------------------------------------
  # `from` is a list of cidrs/ips; edges split into v4/v6 rules automatically.
  edgeType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Edge name used in counters and IDS rules.";
      };
      ports = mkOption {
        type = types.listOf types.port;
        description = "TCP destination ports.";
      };
      from = mkOption {
        type = types.listOf types.str;
        description = "Source addresses/CIDRs for inbound edges; destinations for outbound observations.";
      };
      direction = mkOption {
        type = types.enum ["inbound" "outbound"];
        default = "inbound";
        description = "Outbound observations feed the IDS but never authorize an inbound connection.";
      };
    };
  };

  p = config.PORTS;

  builtinEdges = [
    # Humans and admin tooling from anywhere on the tailnet.
    {
      name = "ssh-tailnet";
      ports = config.services.openssh.ports;
      from = [
        tailnet4
        tailnet6
      ];
    }
    {
      name = "https-tailnet";
      ports = [
        p.traefikHttp
        p.traefikHttps
      ];
      from = [
        tailnet4
        tailnet6
      ];
    }
    {
      name = "dns-tailnet";
      ports = [p.dns];
      from = [
        tailnet4
        tailnet6
      ];
    }
  ];

  serviceEdges =
    (lib.optionals (config.services.prometheus.exporters.node.enable or false) [
      {
        name = "prometheus-scrape-node";
        ports = [p.prometheusNodeExporter];
        from = scrapeSources ++ ["127.0.0.1"];
      }
    ])
    # The rest of the scrape universe: any PORTS prometheus* key that a service on this
    # box actually serves - declared generously (all prometheus* ports from hub IPs);
    # ports nothing listens on are dead rules, and dead rules are cheap.
    ++ (lib.optionals (scrapeSources != []) [
      {
        name = "prometheus-scrape";
        ports = lib.attrValues (lib.filterAttrs (n: _: lib.hasPrefix "prometheus" n) p);
        from = scrapeSources;
      }
    ])
    ++ (lib.optionals (config.MODULES.services.immich.enable or false) [
      {
        name = "immich-machine-learning-remote";
        direction = "outbound";
        ports = [p.immichMachineLearning];
        from = immichRemoteMlSources;
      }
    ])
    ++ (lib.optionals (config.services.immich.machine-learning.enable or false) [
      {
        name = "immich-machine-learning";
        ports = [p.immichMachineLearning];
        from = immichServerSources ++ ["127.0.0.1"];
      }
    ])
    ++ (lib.optionals (config.services.loki.enable or false) [
      # 2026-11-14, audit #6: Loki is auth_enabled=false, so this port is a full
      # read+write API. Only the declared pushers reach it now - the exact list
      # loki.nix feeds the iptables rule (MODULES.services.loki.fleetPushSources,
      # derived from the fleet's fleetPushTargets), so filter and IDS share one
      # source. An empty list = no rule = fail closed. Loopback Grafana/Alloy never
      # traverse the tap (the chain is iifname-gated), so reads stay exempt.
      {
        name = "loki-ingest";
        ports = [p.loki];
        from = config.MODULES.services.loki.fleetPushSources or [];
      }
      # Outbound twin: a pushing host's own SYNs to the aggregator land on its tap;
      # undeclared egress is SG-DRIFT just as much as ingress (immich precedent,
      # 2026-10-27). Derived from URLs (fleetAggregators), so microVM guests - who
      # see nixosConfigurations={} - are covered on their client side too.
      {
        name = "loki-fleet-push";
        direction = "outbound";
        ports = [p.loki];
        from = config.MODULES.services.loki.fleetAggregators or [];
      }
    ])
    ++ (lib.optionals (config.MODULES.services.coroot.enable or false) [
      {
        name = "coroot";
        ports = [p.coroot];
        # 2026-11-14 (audit #17): the whole-tailnet blanket was the graph's last
        # 100.64/10 accept on the server; the ONLY legitimate dialers are flake
        # hosts running the agent (agentEnable hosts + the server's own local
        # agent over loopback - loopback never traverses the tap). Verified live
        # before narrowing: akos01:8080 had exactly one non-loopback established
        # client, hp (100.92.36.52); nothing else dials 8080/4317. The
        # microvm@vm-agents guest needs NO literal of its own: its pushes arrive
        # SNATed through hp's exit-node path, i.e. as hp's IP (measured on akos01
        # 2026-11-14: node "vm-agents" reporting, source 100.92.36.52). A future
        # off-tailnet dialer (lab robot direct) would need a literal here - a
        # guest sees nixosConfigurations={} so peerIPs cannot carry such hosts.
        from = peerIPs;
      }
    ])
    ++ (lib.optionals (config.services.syncthing.enable or false) [
      {
        name = "syncthing-bep";
        ports = [p.syncthingSync];
        # Phones are not nixosConfigurations; Syncthing authenticates each device key.
        from = [tailnet4 tailnet6];
      }
    ]);

  edges =
    builtinEdges
    ++ serviceEdges
    ++ cfg.allow
    ++ lib.optionals config.services.ollama.enable [
      {
        name = "ollama-fleet";
        ports = [p.ollama];
        from = peerIPs;
      }
    ]
    ++ lib.optionals config.MODULES.services.fastdds.enable [
      {
        name = "fastdds-tailnet";
        ports = [p.fastddsDiscovery p.fastddsData];
        from = [tailnet4 tailnet6];
      }
    ]
    ++ lib.mapAttrsToList (name: serve: {
      name = "tailscale-serve-${name}";
      ports =
        lib.optional (serve.httpsPort != null) serve.httpsPort
        ++ lib.optional (serve.httpPort != null) serve.httpPort
        ++ serve.tcpPorts ++ serve.tlsTermTcpPorts;
      from = [tailnet4 tailnet6];
    })
    config.MODULES.networking.tailscale.serve;

  # A separate base chain is essential: an ACCEPT in another base chain does
  # not bypass it, regardless of how often tailscaled reorders its own jumps.
  nft = "${pkgs.nftables}/bin/nft";
  nftSet = xs: "{ ${concatStringsSep ", " xs} }";
  ruleFor = e:
    lib.concatMapStringsSep "\n" (src: "${
      if isV6 src
      then "ip6"
      else "ip"
    } saddr ${src} tcp dport ${nftSet (map toString e.ports)} counter accept")
    e.from;
  inboundEdges = lib.filter (e: (e.direction or "inbound") == "inbound" && e.ports != []) edges;
  udpPorts =
    lib.unique (config.networking.firewall.allowedUDPPorts
      ++ lib.concatMap (tap: (config.networking.firewall.interfaces.${tap}.allowedUDPPorts or [])) cfg.taps);
  udpRanges =
    config.networking.firewall.allowedUDPPortRanges
    ++ lib.concatMap (tap: (config.networking.firewall.interfaces.${tap}.allowedUDPPortRanges or [])) cfg.taps;
  udpElements = map toString udpPorts ++ map (r: "${toString r.from}-${toString r.to}") udpRanges;
  rulesFile = pkgs.writeText "fleet-service-graph.nft" ''
    add table inet fleet_service_graph
    flush table inet fleet_service_graph
    table inet fleet_service_graph {
      chain input {
        type filter hook input priority 10; policy accept;
        ct state established,related accept
        iifname ${nftSet (map builtins.toJSON cfg.taps)} jump tailnet
        ${lib.optionalString (cfg.enforce && cfg.outboundOnlyInterfaces != []) ''
      iifname ${nftSet (map builtins.toJSON cfg.outboundOnlyInterfaces)} meta l4proto { icmp, ipv6-icmp } accept
      iifname ${nftSet (map builtins.toJSON cfg.outboundOnlyInterfaces)} counter drop
    ''}
      }
      chain tailnet {
        ct state invalid drop
        ${concatStringsSep "\n" (map ruleFor inboundEdges)}
        ${lib.optionalString (udpElements != []) "udp dport ${nftSet udpElements} counter accept"}
        meta l4proto tcp limit rate 20/minute log prefix "sg-seen: "
        ${lib.optionalString cfg.enforce ''
      meta l4proto tcp counter reject with tcp reset
      meta l4proto udp counter drop
    ''}
      }
    }
  '';
  # Remove the old jump on migration/stop; never touch Tailscale's chains.
  legacyCleanup = concatStringsSep "" (lib.concatMap (fam:
    map (tap: ''
      while ${fam} -w -C INPUT -i ${tap} -p tcp -m tcp --syn -m comment --comment "sg: tap" -j SG-INPUT 2>/dev/null; do
        ${fam} -w -D INPUT -i ${tap} -p tcp -m tcp --syn -m comment --comment "sg: tap" -j SG-INPUT
      done
    '')
    cfg.taps
    ++ [
      ''
        ${fam} -w -F SG-INPUT 2>/dev/null || true
        ${fam} -w -X SG-INPUT 2>/dev/null || true
      ''
    ]) ["iptables" "ip6tables"]);
  host = config.networking.hostName;
  # ---- EVE -> Loki/Prometheus via the Alloy fleet writer -------------------------------
  # One tail per instance (the tap and, when enabled, the public edge tap), ONE
  # loki.process each that FANS the raw EVE lines out: every event type rides to Loki
  # as structured streams; the `stats` events (always emitted, see the yaml) are
  # additionally turned into Prometheus gauges (exposed on Alloy's own /metrics,
  # scraped by the `alloy` job in modules/services/loki.nix) and then dropped
  # from the log path. Labels stay low-cardinality per the contract in
  # modules/services/loki.nix: event_type/in_iface/sid/action/vhost/status/method -
  # src/dst/URI/UA remain in the JSON line for query-time `| json`.
  evePipeline = name: job: dir: tap: ''
        loki.source.file "${name}" {
          targets = [
            { __path__ = "/var/log/${dir}/eve.json", job = "${job}", host = "${host}", tap = "${tap}" },
          ]
          forward_to = [loki.process.${name}.receiver]
        }

        loki.process "${name}" {
          forward_to = [loki.write.fleet.receiver]

          stage.json {
            expressions = {
              event_type  = "event_type",
              in_iface    = "in_iface",
              sid         = "alert.signature_id",
              sig         = "alert.signature",
              action      = "alert.action",
              category    = "alert.category",
              vhost       = "http.hostname",
              status      = "http.status",
              method      = "http.http_method",
              sni         = "tls.sni",
              src_ip      = "src_ip",
              dest_ip     = "dest_ip",
              dest_port   = "destination_port",
              url         = "http.url",
              user_agent  = "http.http_user_agent",
              uptime      = "stats.uptime",
              kpackets    = "stats.capture.kernel_packets",
              kdrops      = "stats.capture.kernel_drops",
              dpkts       = "stats.decoder.pkts",
              dbytes      = "stats.decoder.bytes",
              invalid     = "stats.decoder.invalid",
              tcpsessions = "stats.tcp.sessions",
              alerts      = "stats.detect.alert",
              flowmem     = "stats.flow.memuse",
              emerg       = "stats.flow.emerg_mode_entered",
              httpmem     = "stats.http.memuse",
            }
          }

          // Promote only what EXISTS: an http event has no sid, an alert has no vhost.
          // stage.labels skips missing extracted keys, so empty label values never reach
          // the Loki index; `filename` (the tailed path) is constant noise - drop it.
          stage.label_drop {
            values = ["filename"]
          }
          stage.labels {
            values = {
              event_type = "",
              in_iface   = "",
              sid        = "",
              sig        = "",
              action     = "",
              category   = "",
              vhost      = "",
              status     = "",
              method     = "",
              sni        = "",
            }
          }

          // Structured metadata (indexed, not labels): keep the per-flow values - peer
          // IPs, port, URL, full UA - attached to the entry for Loki filtering and
          // table panels without bloating the stream index.
          stage.structured_metadata {
            values = {
              src_ip     = "",
              dest_ip    = "",
              dest_port  = "",
              url        = "",
              user_agent = "",
            }
          }

          // Coarse device class on http events (closed 5-value set -> label-safe; the
          // full UA stays in structured metadata). `ua` is promoted to a label only for
          // the duration of the classifier and dropped at the end, so it never reaches
          // Loki. Assignments cascade GENERIC -> SPECIFIC: every browser UA also says
          // "Mozilla/5.0 ... Safari/537", so desktop is stamped first and mobile/tablet/
          // bot overwrite it, bot last (scanners wearing a Mozilla mask stay bots).
          stage.match {
            selector = "{event_type=\"http\"}"

            stage.labels {
              values = { ua = "user_agent" }
            }
            stage.static_labels {
              values = { device_class = "other" }
            }
            stage.match {
              selector = "{ua=~\"(?i).*(mozilla|chrome|safari|firefox|edg).*\"}"
              stage.static_labels {
                values = { device_class = "desktop" }
              }
            }
            stage.match {
              selector = "{ua=~\"(?i).*(ipad|tablet).*\"}"
              stage.static_labels {
                values = { device_class = "tablet" }
              }
            }
            stage.match {
              selector = "{ua=~\"(?i).*(mobile|iphone|ipod|android).*\"}"
              stage.static_labels {
                values = { device_class = "mobile" }
              }
            }
            stage.match {
              selector = "{ua=~\"(?i).*(bot|crawl|spider|scan|curl|wget|python|aiohttp|go-http|okhttp|java|libwww|masscan|zgrab|nuclei|httpx|censys|shodan).*\"}"
              stage.static_labels {
                values = { device_class = "bot" }
              }
            }
            stage.label_drop {
              values = ["ua"]
            }
          }

          // Engine counters -> Prometheus gauges. Labels inherit from the entry
          // (host/tap); gauge (not counter) because Suricata's stats are cumulative-
          // since-boot values it re-sets every interval - rate()/increase() on them read
          // correctly, and an engine restart resets them like a counter reset. Default
          // max_idle (5m) expires the whole set shortly after a tap dies, which is what
          // the absent() alert rule in the Network IDS dashboard keys on.
          stage.match {
            selector = "{event_type=\"stats\"}"

            stage.metrics {
    metric.gauge {
                name   = "suricata_uptime_seconds"
                action = "set"
                source = "uptime"
                description = "Engine uptime; series expiring (max_idle) means the tap died."
              }
    metric.gauge {
                name   = "suricata_capture_kernel_packets_total"
                action = "set"
                source = "kpackets"
                description = "Packets delivered to userspace by the capture module (cumulative)."
              }
    metric.gauge {
                name   = "suricata_capture_kernel_drops_total"
                action = "set"
                source = "kdrops"
                description = "Packets the capture ring dropped (cumulative) - the DPI blind-spot meter."
              }
    metric.gauge {
                name   = "suricata_decoder_packets_total"
                action = "set"
                source = "dpkts"
                description = "Packets decoded (cumulative)."
              }
    metric.gauge {
                name   = "suricata_decoder_bytes_total"
                action = "set"
                source = "dbytes"
                description = "Bytes decoded (cumulative)."
              }
    metric.gauge {
                name   = "suricata_decoder_invalid_total"
                action = "set"
                source = "invalid"
                description = "Undecodable packets (cumulative)."
              }
    metric.gauge {
                name   = "suricata_tcp_sessions"
                action = "set"
                source = "tcpsessions"
                description = "Open TCP sessions tracked by the stream engine."
              }
    metric.gauge {
                name   = "suricata_detect_alerts_total"
                action = "set"
                source = "alerts"
                description = "Rule alerts emitted since boot (per-SID history lives in Loki)."
              }
    metric.gauge {
                name   = "suricata_flow_memuse_bytes"
                action = "set"
                source = "flowmem"
                description = "Flow engine memory in use."
              }
    metric.gauge {
                name   = "suricata_flow_emerg_mode_entered_total"
                action = "set"
                source = "emerg"
                description = "Flow emergency-mode entries, memcap pressure (cumulative)."
              }
    metric.gauge {
                name   = "suricata_http_memuse_bytes"
                action = "set"
                source = "httpmem"
                description = "HTTP engine memory in use."
              }
            }

            // stats lines are metrics-only: they never need to occupy Loki chunks.
            stage.drop {
              expression          = ".*"
              drop_counter_reason = "eve_stats_metric_only"
            }
          }
        }
  '';
  # Shared yaml renderer for both suricata instances (the tailscale0 tap and the public
  # edge tap). Two render traps, each proven fatal by `suricata -T` on the built artifact
  # (2026-10-25 review #1): a %YAML directive MUST be followed by a `---` document-start
  # line, and the af-packet keys must nest INSIDE their "- interface" item - the old
  # indented-string interpolation shifted only the first list line, leaving cluster-id
  # level with the dash (parse error). The list is plain \n-concatenation, immune to
  # literal-indent math. Engine init also aborts when the classification/reference/
  # threshold files are MISSING (the old artifact died on exactly this), so every
  # instance gets the stub trio - sg/edge rules use no classification/reference tags,
  # the files only have to EXIST. Key names are Suricata's literal options
  # (`classification-file`, `reference-config-file` - NOT `reference-config`; 8.0.3
  # ignores unknown keys and then fatals resolving its default), written explicitly so a
  # sysconfdir change upstream cannot strand the defaults.
  instanceYaml = {
    dir,
    confDir,
    homeNets,
    taps,
    ruleFiles,
    eveTypes,
  }: let
    afPacket = lib.concatStrings (lib.imap0 (i: t:
      "  - interface: ${t.interface}\n"
      + "    cluster-id: ${toString t.clusterId}\n"
      + "    cluster-type: cluster_flow\n"
      + "    defrag: yes\n"
      + "    use-mmap: yes\n"
      + lib.optionalString (t.bpfFilter != null)
      "    bpf-filter: \"${t.bpfFilter}\"\n")
    taps);
  in ''
    %YAML 1.1
    ---
    vars:
      address-groups:
        HOME_NET: "[${concatStringsSep ", " homeNets}]"
        EXTERNAL_NET: "!$HOME_NET"
    default-log-dir: /var/log/${dir}
    default-rule-path: /etc/suricata/${confDir}
    classification-file: /etc/suricata/${confDir}/classification.config
    reference-config-file: /etc/suricata/${confDir}/reference.config
    threshold-file: /etc/suricata/${confDir}/threshold.config
    # /run/<dir> arrives via the unit's RuntimeDirectory= (owned by the suricata user);
    # the tap keeps the historical /run/suricata/suricata.pid path, the edge instance
    # gets its own so the two engines never fight over a pidfile. unix-command is on for
    # both: the `uptime`/`iface-stat` socket is the human debugging door (suricatasc).
    pid-file: /run/${dir}/suricata.pid
    unix-command:
      enabled: auto
      filename: /run/${dir}/command.socket
    rule-files:
    ${concatStringsSep "\n" (map (r: "  - ${r}") ruleFiles)}
    af-packet:
    ${afPacket}
    outputs:
      - eve-log:
          enabled: yes
          filetype: regular
          filename: eve.json
          types:
    ${concatStringsSep "\n" (map (t: "        - ${t}") (eveTypes ++ lib.optionals cfg.suricata.metrics ["stats"]))}
    threshold:
      - generator: sid
        threshold:
          type: limit
          track: by_src
          count: 20
          seconds: 60
  '';
in {
  options.MODULES.security.serviceGraph = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Observe or enforce the fleet's host ingress policy independently of VPN firewall ordering.";
    };

    enforce = mkOption {
      type = types.bool;
      default = false;
      description = "Reject undeclared tailnet TCP, allow only declared UDP ports, and deny new inbound traffic on outboundOnlyInterfaces.";
    };

    taps = mkOption {
      type = types.nonEmptyListOf types.str;
      default = ["tailscale0"];
      description = ''
        Interfaces whose inbound traffic feeds the independent nftables policy. Everything else - wire, docker
        bridges, loopback - keeps its legacy firewall semantics; the interface scope is
        what makes `enforce` safe to flip.
      '';
    };

    outboundOnlyInterfaces = mkOption {
      type = types.listOf types.str;
      default = ["wt0"];
      description = "VPN interfaces that may carry replies to local connections but accept no new inbound connections in enforce mode.";
    };

    allow = mkOption {
      type = types.listOf edgeType;
      default = [];
      description = "Host-local edges the fleet table does not know about.";
    };

    suricata.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Passive Suricata tap whose pass-list is generated from the edge table.";
    };

    suricata.eveTypes = mkOption {
      type = types.listOf types.str;
      default = ["alert" "http" "tls"];
      example = ["alert"];
      description = ''
        EVE event types the tap writes. Beyond `alert` these are the app-layer record of
        what actually crossed the tap - Suricata parses the flows and logs HTTP requests
        (method/host/URI/status/UA/XFF) and TLS handshakes (SNI, JA3/JA4) with no rules
        involved: `http`/`tls` events fire on every decoded flow, signatures only decide
        the `alert` events.
      '';
    };

    suricata.metrics = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Export Suricata's internal counters to Prometheus: the EVE `stats` events the tap
        already writes are converted to suricata_* gauges by the Alloy pipeline and scraped
        off Alloy's own /metrics (the `alloy` job in modules/services/loki.nix). Turning
        this off keeps the log streams but mints no metrics.
      '';
    };

    suricata.edge = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          DPI tap for the PUBLIC Traefik entry points: a second Suricata instance mirroring
          `lo`, bpf-scoped to the cloudflare/funnel entry-point ports, logging every parsed
          HTTP request (EVE http) and alerting on the local EDGE-* signatures (scanner
          sweeps, path probes, tool UAs). Needed because the Cloudflare Tunnel delivers
          public traffic as cleartext HTTP from cloudflared on loopback - the tailscale0
          tap never sees it, and it carries the real client only in X-Forwarded-For, which
          EVE http logs as x_forwarded_for.
        '';
      };

      ports = mkOption {
        type = types.nonEmptyListOf types.port;
        default = [p.traefikCloudflare p.traefikFunnel];
        defaultText = lib.literalExpression "[PORTS.traefikCloudflare PORTS.traefikFunnel]";
        description = ''
          Loopback ports the edge tap's BPF filter admits (Traefik's public-facing entry
          points). Kept explicit so no internal loopback service ever gets parsed/alerted.
        '';
      };
    };
  };

  config =
    mkMerge [
      {
        assertions = [
          {
            assertion = !cfg.suricata.edge.enable || cfg.suricata.enable;
            message = "MODULES.security.serviceGraph.suricata.edge.enable is the second tap of the suricata half - set MODULES.security.serviceGraph.suricata.enable too (it owns the user, the engine package and the alloy shipping pipeline it reuses).";
          }
        ];
      }

      (mkIf cfg.enable {
        environment.etc."fleet-service-graph.nft".source = rulesFile;
        networking.firewall.extraCommands = "${nft} -f ${rulesFile}\n" + legacyCleanup;
        networking.firewall.extraStopCommands =
          ''
            ${nft} delete table inet fleet_service_graph 2>/dev/null || true
          ''
          + legacyCleanup;
      })

      (
        mkIf (cfg.enable && cfg.suricata.enable) {
          # The structured shipping itself only exists while the Alloy fleet writer does
          # (modules/services/loki.nix); without a local Loki the journald fallback tail
          # unit below keeps EVE reachable via journalctl.
          MODULES.services.loki.extraAlloyBlocks = lib.mkIf config.MODULES.services.loki.enable (
            [
              (evePipeline "suricata_eve" "suricata" "suricata" "tailscale")
            ]
            ++ lib.optionals cfg.suricata.edge.enable [
              (evePipeline "suricata_edge_eve" "suricata-edge" "suricata-edge" "edge")
            ]
          );

          # The board that makes all of this viewable, git-provisioned into Grafana
          # (uid fleet-ids, folder "Fleet"): alert history/leaders from Loki (fleet
          # stream -> both taps from either box) + this host's engine stats from
          # Prometheus (job=alloy). Loki panels pin the uids provisioned by
          # modules/services/loki.nix ("loki"/"loki-fleet"); prometheus is referenced by
          # type (the default datasource - its provisioned row has no pinned uid).
          MODULES.services.grafana.providedDashboards = lib.mkIf config.MODULES.services.grafana.enable {
            "fleet-ids.json" = ../../dashboards/fleet-ids.json;
          };

          # Fleet Prometheus alert rules, shipped via /etc and copied into the
          # Syncthing-synced rulesDir by the tmpfiles C+ below (the dir itself is
          # runtime state; its CONTENTS start from git). prometheus-rules-reload.path
          # fires on the copy and reloads prometheus. Dotted + mkIf (not
          # `environment.etc = optionalAttrs ...`): the set form would collide with
          # the dotted suricata etc entries in this same attr set.
          environment.etc."prometheus-rules/service-graph.yml".text =
            lib.mkIf
            (config.MODULES.services.prometheus.enable && cfg.suricata.metrics)
            ''
              groups:
                - name: service-graph
                  rules:
                    # The Alloy-minted suricata_* series expire (max_idle 5m) when an
                    # engine stops writing EVE stats: host down, unit down, or tap gone.
                    # absent() over 10m, not 5m, so the expiry grace can't flap the page.
                    - alert: SuricataTapDown
                      expr: absent(suricata_uptime_seconds)
                      for: 10m
                      labels: { severity: warning }
                      annotations:
                        summary: "No suricata stats on {{ $labels.instance }} - tap engine down or host silent"
                        description: "suricata_uptime_seconds absent > 10m. Check systemctl status suricata suricata-edge and journalctl -u suricata; alert history lives in Loki {job=~\"suricata.*\"}."
                    - alert: SuricataCaptureDrops
                      expr: increase(suricata_capture_kernel_drops_total[15m]) > 100
                      for: 15m
                      labels: { severity: warning }
                      annotations:
                        summary: "Suricata tap {{ $labels.tap }} is dropping packets"
                        description: "The capture ring is overflowing: the IDS (and SG-DRIFT) is going blind under load. Raise af-packet ring sizes or reduce the tap scope."
            '';
          systemd.tmpfiles.rules = lib.mkIf config.MODULES.services.prometheus.enable [
            "C ${config.MODULES.services.prometheus.rulesDir}/service-graph.yml - - - - /etc/prometheus-rules/service-graph.yml"
          ];

          # Pass-list mirrors the nft/iptables edges (v4 rules only - suricata CIDRs for the
          # ULA range would need HOME_NET v6 support; the tap is tailscale0, v4-dominated).
          # Each edge passes BOTH directions with the peer IP pinned: `peer -> any:ports`
          # (this host as the server, seen on our tap) and `any -> peer:ports` (this host as
          # the CLIENT - our tap sees our own outbound SYNs, and an undeclared egress is just
          # as much drift as an undeclared ingress; hp 2026-10-27: akos01's immich dialing
          # hp's ML worker alerted SG-DRIFT on akos01's tap, not hp's).
          environment.etc."suricata/sg.rules".text = let
            passLines = builtins.concatMap (e: let
              peers = builtins.filter (s: !isV6 s) e.from;
              ports = concatStringsSep "," (map toString e.ports);
            in
              map (src: ''pass tcp ${src} any -> any ${ports} (sid:@SID@; rev:1;)'') peers
              ++ map (peer: ''pass tcp any any -> ${peer} ${ports} (sid:@SID@; rev:1;)'') peers)
            edges;
          in ''
            # Generated by modules/security/service-graph.nix - same edges as SG-INPUT.
            ${concatStringsSep "
" (
                lib.imap1 (i: line: lib.replaceString "@SID@" (toString (9100000 + i)) line) passLines
              )}
            alert tcp any any -> any any (msg:"SG-DRIFT undeclared SYN on tap interface"; flags:S; flow:to_server; sid:9000999; rev:1;)
          '';
          environment.etc."suricata/suricata.yaml".text = instanceYaml {
            dir = "suricata";
            confDir = "suricata";
            homeNets = [tailnet4 tailnet6];
            taps =
              lib.imap0 (i: tap: {
                interface = tap;
                clusterId = 99 + i;
                bpfFilter = null;
              })
              cfg.taps;
            ruleFiles = ["sg.rules"];
            eveTypes = cfg.suricata.eveTypes;
          };
          environment.etc."suricata/classification.config".text = ''
            # Generated stub - sg.rules carries no classtype/sid classifications.
          '';
          environment.etc."suricata/reference.config".text = ''
            # Generated stub - sg.rules carries no reference: tags.
          '';
          environment.etc."suricata/threshold.config".text = ''
            # Generated stub - thresholds are set inline in suricata.yaml.
          '';
          users.users.suricata = {
            group = "suricata";
            isSystemUser = true;
          };
          users.groups.suricata = {};
          systemd.services.suricata = {
            description = "Suricata passive tap on the service-graph tap interface";
            wantedBy = ["multi-user.target"];
            after = ["network-online.target"];
            wants = ["network-online.target"];
            # sg.rules/suricata.yaml are environment.etc files read only at process start;
            # without this, edge changes land on disk but the tap keeps alerting against
            # the stale pass-list until the next reboot (suricata has no rule reload).
            restartTriggers = [
              config.environment.etc."suricata/sg.rules".text
              config.environment.etc."suricata/suricata.yaml".text
            ];
            serviceConfig = {
              # Foreground; Restart=always because the tap legitimately may not exist yet
              # (tailscale up later) - af-packet re-attaches when the tap appears. Bare
              # --af-packet sniffs every interface the yaml block above lists.
              ExecStart = "${pkgs.suricata}/bin/suricata -c /etc/suricata/suricata.yaml --af-packet";
              User = "suricata";
              DynamicUser = lib.mkForce false;
              Restart = "always";
              RestartSec = "30s";
              AmbientCapabilities = [
                "CAP_NET_RAW"
                "CAP_NET_ADMIN"
              ];
              ProtectSystem = "strict";
              # /var/log/suricata, root-owned→suricata-owned, created BEFORE the daemon
              # by systemd itself. The removed preStart script ran as User=suricata
              # (User= covers ExecStartPre too - the old comment here was wrong), so its
              # chown could never work; LogsDirectory is the root-side primitive. Holds
              # the pidfile + the unix-command socket too (see the yaml pid-file key).
              LogsDirectory = "suricata";
              RuntimeDirectory = "suricata";
              ReadWritePaths = ["/var/log/suricata"];
            };
          };
          systemd.services.suricata-eve-tail = lib.mkIf (!config.MODULES.services.loki.enable) {
            description = "Ship Suricata EVE JSON into journald (fallback: no local Loki for the Alloy fleet writer)";
            wantedBy = ["multi-user.target"];
            after = ["suricata.service"];
            wants = ["suricata.service"];
            serviceConfig = {
              ExecStart = ''
                ${pkgs.bash}/bin/bash -c 'until [ -f /var/log/suricata/eve.json ]; do sleep 2; done; exec ${pkgs.coreutils}/bin/tail -F /var/log/suricata/eve.json | ${config.systemd.package}/bin/systemd-cat -t suricata-eve -p info'
              '';
              Restart = "always";
              RestartSec = "10s";
            };
          };
        }
      )

      # Separate mkMerge element (NOT a `//` on the set above): `//` is a shallow
      # attr override and would replace the whole `environment` attr, silently
      # deleting the sg tap's etc files whenever the edge tap is enabled.
      (mkIf (cfg.enable && cfg.suricata.edge.enable) (let
        # The public-edge instance. Loopback is where the Cloudflare tunnel hands the
        # world's requests to Traefik in cleartext (TLS ended at Cloudflare's edge), so
        # this tap - unlike the encrypted tailscale0 wire - sees every public request
        # parseable: EVE http events (host/URI/status/UA and xff = the real client IP)
        # plus content-rule alerts. The BPF filter is load-bearing: without it this
        # mirror would parse EVERY internal loopback service too.
        edgePortsStr = concatStringsSep " or " (map (pt: "tcp port ${toString pt}") cfg.suricata.edge.ports);
        # Local signatures, in-git like sg.rules (sid block 9200000+). Honest scope:
        # behind Cloudflare this is cheap anomaly triage, not a WAF. NO pass list and no
        # SYN-drift rule here: every edge flow is loopback->loopback, so any source-based
        # pass would suppress the whole instance, and the BPF filter already IS the scope.
        # Rule variables are safe in ''-strings (only ${ interpolates).
        # @SID@ is replaced PER OCCURRENCE: the ruleset is one multi-line string and
        # a single imap1 counter would stamp every rule with the same sid - suricata
        # -T dies on "Duplicate signature" (measured 2026-11-12). Comments/blank
        # lines pass through unnumbered.
        edgeRulesSrc = ''
          # ---- EDGE-*: generic probe/attack patterns on the public entry ports ------
          # Sticky http buffers are ONLY legal in tcp/udp rules (suricata -T rejects
          # them in "ip" rules, measured 2026-11-11); alerts gate on flow:to_server.
          # Path traversal (encoded forms included).
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TRAVERSAL relative path in URI"; flow:to_server; http.uri; content:"../"; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TRAVERSAL url-encoded dot-dot-slash"; flow:to_server; http.uri; content:"%2e%2e%2f"; nocase; sid:@SID@; rev:1;)
          # Null byte in URI (parameter-injection tooling).
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-NULLBYTE in URI"; flow:to_server; http.uri; content:"|00|"; sid:@SID@; rev:1;)
          # Mass-grabbed config/backup files.
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE dotfile or backup fetch"; flow:to_server; http.uri; content:".env"; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE dotfile or backup fetch"; flow:to_server; http.uri; content:".git/config"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE dotfile or backup fetch"; flow:to_server; http.uri; content:".bak"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE dotfile or backup fetch"; flow:to_server; http.uri; content:".sql"; nocase; sid:@SID@; rev:1;)
          # The scanner back-catalogue.
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:"/wp-login"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:"/wp-admin"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:"/xmlrpc.php"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:"phpmyadmin"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:"/cgi-bin/"; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-PROBE scanner path sweep"; flow:to_server; http.uri; content:">BASE64"; nocase; sid:@SID@; rev:1;)
          # Shellshock-shaped header values (still swept by mass scanners). The literal
          # payload is "() { :;\" - matched via its "() {" prefix.
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-SHELLSHOCK header value"; flow:to_server; http.header; content:"() {"; sid:@SID@; rev:1;)
          # Known tooling user-agents (full UA rides in Loki structured metadata).
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"sqlmap"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"nikto"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"masscan"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"zgrab"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"nuclei"; nocase; sid:@SID@; rev:1;)
          alert tcp $EXTERNAL_NET any -> $HOME_NET any (msg:"EDGE-TOOL known attack/scanner UA"; flow:to_server; http.user_agent; content:"censys"; nocase; sid:@SID@; rev:1;)
        '';
        # Replace every "@SID@" left-to-right with base+1, base+2, ...
        replaceSids = base: text: let
          parts = lib.splitString "@SID@" text;
          go = i: acc:
            if i == lib.length parts
            then acc
            else
              go (i + 1)
              (acc
                + lib.lists.elemAt parts i
                + lib.optionalString (i < lib.length parts - 1) (toString (base + i + 1)));
        in
          go 0 "";
        edgeRules = replaceSids 9200000 edgeRulesSrc;
      in {
        assertions = [
          {
            assertion = config.MODULES.networking.traefik.enable && (config.MODULES.networking.traefik.cloudflare.services != {} || config.MODULES.networking.traefik.funnel.enable);
            message = "MODULES.security.serviceGraph.suricata.edge.enable taps the PUBLIC Traefik entry points - this host routes none (no cloudflare services, no funnel). Leave it off or publish something first.";
          }
        ];

        environment.etc."suricata/edge/edge.rules".text = ''
          # Generated by modules/security/service-graph - local public-edge signatures for
          # the loopback tap (Cloudflare tunnel + funnel hand-offs). Auditable in git like
          # sg.rules; no remote ruleset is fetched.
          ${edgeRules}
        '';
        environment.etc."suricata/edge/suricata.yaml".text = instanceYaml {
          dir = "suricata-edge";
          confDir = "edge";
          homeNets = ["127.0.0.0/8"];
          taps = [
            {
              interface = "lo";
              clusterId = 250;
              bpfFilter = edgePortsStr;
            }
          ];
          ruleFiles = ["edge.rules"];
          eveTypes = cfg.suricata.eveTypes;
        };
        environment.etc."suricata/edge/classification.config".text = ''
          # Generated stub - edge.rules carries no classtype/sid classifications.
        '';
        environment.etc."suricata/edge/reference.config".text = ''
          # Generated stub - edge.rules carries no reference: tags.
        '';
        environment.etc."suricata/edge/threshold.config".text = ''
          # Generated stub - thresholds are set inline in suricata.yaml.
        '';

        systemd.services.suricata-edge = {
          description = "Suricata DPI tap on loopback (public Traefik entry points)";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target" "traefik.service"];
          wants = ["network-online.target"];
          restartTriggers = [
            config.environment.etc."suricata/edge/edge.rules".text
            config.environment.etc."suricata/edge/suricata.yaml".text
          ];
          serviceConfig = {
            # cluster-id 250 differs from the sg tap (99+) so the two engines can hold
            # lo/tailscale0 fan-out sockets side by side; lo always exists, so unlike the
            # tailscale tap this unit has no re-attach story to keep - just restart.
            ExecStart = "${pkgs.suricata}/bin/suricata -c /etc/suricata/edge/suricata.yaml --af-packet";
            User = "suricata";
            DynamicUser = lib.mkForce false;
            Restart = "always";
            RestartSec = "30s";
            AmbientCapabilities = [
              "CAP_NET_RAW"
              "CAP_NET_ADMIN"
            ];
            ProtectSystem = "strict";
            LogsDirectory = "suricata-edge";
            RuntimeDirectory = "suricata-edge";
            ReadWritePaths = ["/var/log/suricata-edge"];
          };
        };
      }))
    ];
}
