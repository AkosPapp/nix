# PLAN.md §7 decision (2026-10-24 review): a SERVICE GRAPH for east-west traffic, enforced
# by the packet filter and OBSERVED by a passive IDS. One module, two halves, so a host
# can run either:
#
#   * The filter half is an iptables chain jumped from the TOP of INPUT, scoped to NEW
#     TCP arriving on the tap interfaces (tailscale0 by default - the same iptables
#     transport as the jail egress chains in modules/security/jail.nix; nixpkgs'
#     networking.nftables.enable is NOT an option because it blacklists ip_tables and
#     would silently kill every jail chain at boot). Flows matching a declared edge are
#     ACCEPTed outright. Everything else is LOGged (`sg-`-prefixed, rate-limited):
#       - log-only mode (default) then RETURNs, so today's firewall semantics are
#         untouched and the log alone is the drift signal - a line for a flow nobody
#         declared means the graph needs a row (or someone opened something they
#         shouldn't have);
#       - enforce mode DROPs instead - the graph becomes stricter than the legacy
#         firewall, which is the point of drawing it. Flip per host after a week of
#         explainable `sg-seen:` logs.
#   * The Suricata half is DETECTION ONLY (af-packet mirror on the tap interface, never
#     a queue/bridge in the path). Its pass-list is GENERATED from the same edge table,
#     so the IDS and the filter cannot disagree; everything else's SYN alerts
#     (`SG-DRIFT`). EVE JSON is tailed into journald (suricata-eve-tail) and rides the
#     Alloy->Loki spine; no remote rulesets are fetched - the local edge rules are the
#     entire set, which keeps the whole detection story auditable in-git.
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

  # ---- the edge table ---------------------------------------------------------------
  # `from` is a list of cidrs/ips; edges split into v4/v6 rules automatically.
  edgeType = types.submodule {
    options = {
      name = mkOption {type = types.str;};
      ports = mkOption {type = types.listOf types.port;};
      from = mkOption {type = types.listOf types.str;};
    };
  };

  p = config.PORTS;

  builtinEdges = [
    # Humans and admin tooling from anywhere on the tailnet.
    {
      name = "ssh-tailnet";
      ports = [22];
      from = [
        tailnet4
        tailnet6
      ];
    }
    {
      name = "https-tailnet";
      ports = [
        80
        443
      ];
      from = [
        tailnet4
        tailnet6
      ];
    }
    {
      name = "dns-tailnet";
      ports = [53];
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
    ++ (lib.optionals (config.services.loki.enable or false) [
      # Alloy agents on every host push here; the tailnet blanket mirrors the existing
      # firewall openness - narrowing it to peer IPs is exactly the graph's job once
      # observed.
      {
        name = "loki-ingest";
        ports = [p.loki];
        from = [tailnet4];
      }
    ])
    ++ (lib.optionals (config.MODULES.services.coroot.enable or false) [
      {
        name = "coroot";
        ports = [
          p.coroot
          4317 # OTLP: node/agents push, mirrors coroot.nix's tailscale0 rule
        ];
        from = [tailnet4];
      }
    ])
    ++ (lib.optionals (config.services.syncthing.enable or false) [
      {
        name = "syncthing-bep";
        ports = [p.syncthingSync];
        from = map (x: "${x}/32") peerIPs;
      }
    ]);

  edges = builtinEdges ++ serviceEdges ++ cfg.allow;

  # ---- renderers ---------------------------------------------------------------------
  # iptables multiport caps at 15 ports per rule - chunk.
  chunks = xs:
    if xs == []
    then []
    else [(lib.take 15 xs)] ++ chunks (lib.drop 15 xs);

  ruleFor = e:
    concatStringsSep "" (
      map (src:
        concatStringsSep "" (
          map (chunk: ''
            ${
              if isV6 src
              then "ip6tables"
              else "iptables"
            } -w -t filter -A SG-INPUT -p tcp -s ${src} \
              -m multiport --dports ${concatStringsSep "," (map toString chunk)} \
              -m comment --comment "${e.name}" -j ACCEPT
          '') (chunks e.ports)
        ))
      e.from
    );

  hasV6 = builtins.any (e: builtins.any isV6 e.from) edges;

  # One jump per tap, interface-scoped. The scope is load-bearing: without -i, every
  # loopback SYN (traefik -> backends, cloudflared -> traefik) walks SG-INPUT too, and
  # flipping `enforce` would REJECT the east-west traffic the edges file deliberately
  # leaves to the jails. `-I INPUT 1` per tap; a failed insert (already present after a
  # rules reload) is tolerated, the stop script deletes by full spec.
  jumpFor = fam: tap: ''
    ${fam} -w -t filter -I INPUT 1 -i ${tap} -p tcp -m tcp --syn -m comment --comment "sg: tap" -j SG-INPUT 2>/dev/null || true
  '';
  # -D matches by full rule spec (a rule *number* cannot be combined with a spec).
  unjumpFor = fam: tap: ''
    ${fam} -w -t filter -D INPUT -i ${tap} -p tcp -m tcp --syn -m comment --comment "sg: tap" -j SG-INPUT 2>/dev/null || true
  '';

  v6Script = lib.optionalString hasV6 ''
    ip6tables -w -t filter -N SG-INPUT 2>/dev/null || ip6tables -w -t filter -F SG-INPUT
    ${concatStringsSep "" (map (jumpFor "ip6tables") cfg.taps)}
  '';

  chainScript = ''
    iptables -w -t filter -N SG-INPUT 2>/dev/null || iptables -w -t filter -F SG-INPUT
    ${concatStringsSep "" (map (jumpFor "iptables") cfg.taps)}
    ${v6Script}
    ${concatStringsSep "" (map ruleFor edges)}
    iptables -w -t filter -A SG-INPUT -m limit --limit 20/minute -j LOG --log-prefix "sg-seen: "
    ${
      if cfg.enforce
      then ''iptables -w -t filter -A SG-INPUT -j REJECT --reject-with tcp-reset''
      else ""
    }
    ${
      lib.optionalString hasV6 ''
        ip6tables -w -t filter -A SG-INPUT -m limit --limit 20/minute -j LOG --log-prefix "sg-seen: "
        ${
          if cfg.enforce
          then ''ip6tables -w -t filter -A SG-INPUT -j REJECT --reject-with tcp-reset''
          else ""
        }
      ''
    }
  '';
in {
  options.MODULES.security.serviceGraph = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    enforce = mkOption {
      type = types.bool;
      default = false;
      description = "Drop undeclared tailnet TCP (false = log-only, the ship default).";
    };

    taps = mkOption {
      type = types.nonEmptyListOf types.str;
      default = ["tailscale0"];
      description = ''
        Interfaces whose inbound TCP SYN feed SG-INPUT. Everything else - wire, docker
        bridges, loopback - keeps its legacy firewall semantics; the interface scope is
        what makes `enforce` safe to flip.
      '';
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
  };

  config =
    mkMerge [
      (mkIf cfg.enable {
        networking.firewall.extraCommands = chainScript;
        networking.firewall.extraStopCommands =
          concatStringsSep "" (
            map (tap: (unjumpFor "iptables" tap) + (unjumpFor "ip6tables" tap)) cfg.taps
          )
          + ''
            iptables -w -t filter -F SG-INPUT 2>/dev/null || true
            ip6tables -w -t filter -F SG-INPUT 2>/dev/null || true
            # delete the chains outright once unreferenced (jumps removed above): a bare
            # -F would leave empty SG-INPUT chains mounted in the filter table forever.
            # -X fails while any jump still references the chain - hence || true.
            iptables -w -t filter -X SG-INPUT 2>/dev/null || true
            ip6tables -w -t filter -X SG-INPUT 2>/dev/null || true
          '';
      })

      (mkIf (cfg.enable && cfg.suricata.enable) {
          # Pass-list mirrors the nft/iptables edges (v4 rules only - suricata CIDRs for the
          # ULA range would need HOME_NET v6 support; the tap is tailscale0, v4-dominated).
          environment.etc."suricata/sg.rules".text = let
            passLines = builtins.concatMap (e:
              map (src: ''pass tcp ${src} any -> any ${
                  concatStringsSep "," (map toString e.ports)
                } (sid:@SID@; rev:1;)'')
              (builtins.filter (s: !isV6 s) e.from))
            edges;
          in ''
            # Generated by modules/security/service-graph.nix - same edges as SG-INPUT.
            ${concatStringsSep "
" (
                lib.imap1 (i: line: lib.replaceString "@SID@" (toString (9100000 + i)) line) passLines
              )}
            alert tcp any any -> any any (msg:"SG-DRIFT undeclared SYN on tap interface"; flags:S; flow:to_server; sid:9000999; rev:1;)
          '';
          # Two render traps, each proven fatal by `suricata -T` on the built artifact
          # (2026-10-25 review #1): a %YAML directive MUST be followed by a `---`
          # document-start line, and the af-packet keys must nest INSIDE their
          # "- interface" item - the old indented-string interpolation shifted only the
          # first list line, leaving cluster-id level with the dash (parse error). The
          # list is now plain \n-concatenation, immune to literal-indent math.
          environment.etc."suricata/suricata.yaml".text = let
            afPacket = lib.concatStrings (lib.imap0 (i: tap:
              "  - interface: ${tap}\n"
              + "    cluster-id: ${toString (99 + i)}\n"
              + "    cluster-type: cluster_flow\n"
              + "    defrag: yes\n"
              + "    use-mmap: yes\n")
            cfg.taps);
          in ''
            %YAML 1.1
            ---
            vars:
              address-groups:
                HOME_NET: "[${tailnet4}, ${tailnet6}]"
                EXTERNAL_NET: "!$HOME_NET"
            default-log-dir: /var/log/suricata
            default-rule-path: /etc/suricata
            # Engine init aborts when either file is missing (the old artifact died on
            # exactly this). sg.rules uses no classification/reference tags, so the
            # files only have to EXIST - stubs below. Key names are Suricata's literal
            # options (`classification-file`, `reference-config-file` - NOT
            # `reference-config`; 8.0.3 ignores unknown keys and then fatals resolving
            # its default), written explicitly so a sysconfdir change upstream cannot
            # strand the defaults.
            classification-file: /etc/suricata/classification.config
            reference-config-file: /etc/suricata/reference.config
            threshold-file: /etc/suricata/threshold.config
            rule-files:
              - sg.rules
            af-packet:
            ${afPacket}
            outputs:
              - eve-log:
                  enabled: yes
                  filetype: regular
                  filename: eve.json
                  types:
                    - alert
            threshold:
              - generator: sid
                threshold:
                  type: limit
                  track: by_src
                  count: 20
                  seconds: 60
          '';
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
              # chown could never work; LogsDirectory is the root-side primitive.
              LogsDirectory = "suricata";
              ReadWritePaths = ["/var/log/suricata"];
            };
          };
          systemd.services.suricata-eve-tail = {
            description = "Ship Suricata EVE JSON into journald (Alloy -> Loki from here)";
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
        })
    ];
}
