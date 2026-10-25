# PLAN.md §2 Layer 2 (Tier A) + §3.4 egress LOG - the MODULES.security.jail factoring of the
# pattern hermes-agent.nix pioneered: ProtectSystem=strict + per-uid egress chain + (new) a
# LOG before every REJECT so each blocked lateral move lands in journald -> Loki -> Grafana.
#
# Two backends, one spec: a jailed service declares its jail ONCE here (units, paths, egress
# allow-list) and `backend` decides what enforces it -
#   backend = "jail"    -> systemd serviceConfig hardening + iptables uid-owner egress chain
#   backend = "microvm" -> the firecracker path (PLAN §2.1 user note: "switch without having to
#                          rewrite the whole config", §6). Not wired yet: enabling it fails the
#                          assertion below rather than silently running the service UNjailed.
#                          When mkServiceVM lands it will read these same rows (paths -> VM
#                          disk, egress -> VM network policy, LIMITS row -> VM memory/vcpu).
#
# Egress semantics (identical to hermes-egress so behaviour is provably familiar):
#   - replies to inbound connections RETURN via conntrack ESTABLISHED (Traefik -> service
#     keeps working; only NEW outbound is filtered);
#   - DNS RETURN unless allowDns=false;
#   - explicit loopback allows (allowedLoopbackTCPPorts) for services that talk to neighbours
#     over TCP; DB-over-unix-socket services need none (unix sockets bypass netfilter);
#   - `custom` = verbatim extra iptables -A lines (pins like paseo-hermes' funnel rule);
#   - publicDefault="allow": REJECT (with LOG) only the private ranges - the tailnet and the
#     LAN become the lateral-movement barrier; "deny": REJECT everything not explicitly
#     allowed above (postgres, prometheus, loki, vaultwarden - they should dial out to nobody);
#   - allowTailnet / allowLan drop the corresponding REJECT (syncthing replicates over the
#     tailnet; prometheus scrapes it).
#   IPv4 only, exactly like hermes-egress (no ip6tables counterpart in this repo's pattern);
#   AF_INET6 stays open for legitimate v6 (federation) - revisit with §7's nftables SERVICE_GRAPH.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption mkMerge mkIf types concatMapStringsSep optionalString optional recursiveUpdate;

  cfg = config.MODULES.security.jails;

  privateRanges = {
    loopback = "127.0.0.0/8";
    lan = "10.0.0.0/8";
    lan2 = "172.16.0.0/12";
    lan3 = "192.168.0.0/16";
    tailnet = "100.64.0.0/10";
    linklocal = "169.254.0.0/16";
  };

  sanitize = n:
    builtins.replaceStrings ["_"] ["-"] (lib.toLower n);
  chainOf = name: "j-${sanitize name}-eg";

  jailType = types.submodule (
    {name, ...}: {
      options = {
        enable = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Activate this jail on this host. The table ships specs; hosts flip this.";
        };

        note = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Rationale / egress summary for the reader (PLAN §2.2 style).";
        };

        backend = mkOption {
          type = types.nullOr (types.enum [
            "jail"
            "microvm"
          ]);
          default = null;
          description = "What enforces the spec: systemd-jail now, firecracker microVM when §6 lands.";
        };

        units = mkOption {
          type = types.nonEmptyListOf types.str;
          description = "systemd units this jail hardens. The owning module must create them (asserted).";
        };

        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Uid-owner for the egress chain; null = read User= off the first unit.";
        };

        noEgress = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Skip the egress chain entirely (unit hardening only).";
        };

        readWritePaths = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = ["/srv/searx-static"];
          description = "ReadWritePaths= beyond what StateDirectory/RuntimeDirectory already grant.";
        };

        bindPaths = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "BindPaths= - pre-existing writable trees (hermes-style state outside /var/lib/*).";
        };

        bindReadOnlyPaths = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
        };

        inaccessiblePaths = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "InaccessiblePaths= (the '-' prefix is added automatically).";
        };

        allowedLoopbackTCPPorts = mkOption {
          type = types.nullOr (types.listOf types.port);
          default = null;
          description = "Loopback TCP destinations this service's uid may dial.";
        };

        allowDns = mkOption {
          type = types.nullOr types.bool;
          default = null;
        };

        allowAnyLoopback = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            RETURN every new loopback flow instead of enumerating ports. For the monitoring
            hub (prometheus scrapes a dozen local exporters; the list churns with every
            exporter added) - its containment is the public-deny + lan/tailnet rules.
          '';
        };

        publicDefault = mkOption {
          type = types.nullOr (types.enum [
            "allow"
            "deny"
          ]);
          default = null;
          description = "Disposition for new outbound flows to PUBLIC addresses.";
        };

        allowPublicTCPPorts = mkOption {
          type = types.nullOr (types.listOf types.port);
          default = null;
          description = "Public-dest TCP ports to RETURN in deny mode (no-op in allow mode).";
        };

        allowTailnet = mkOption {
          type = types.nullOr types.bool;
          default = null;
        };

        allowLan = mkOption {
          type = types.nullOr types.bool;
          default = null;
        };

        custom = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = ["iptables -w -A %c -d 1.2.3.4 -p tcp --dport 443 -j RETURN"];
          description = "Verbatim iptables lines appended before the deny block; %c = chain name.";
        };

        hardening = {
          noNewPrivileges = mkOption {
            type = types.nullOr types.bool;
            default = null;
          };
          privateTmp = mkOption {
            type = types.nullOr types.bool;
            default = null;
          };
          restrictAddressFamilies = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
          };
          restrictSuidSgid = mkOption {
            type = types.nullOr types.bool;
            default = null;
          };
          protectKernelModules = mkOption {
            type = types.nullOr types.bool;
            default = null;
          };
          protectKernelTunables = mkOption {
            type = types.nullOr types.bool;
            default = null;
          };
          privatePIDs = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              PrivatePIDs= (systemd 257+): PID namespace so the service cannot even see its
              neighbours' sockets via /proc. Opt-in because it breaks anything that
              pgrep/pkill-s or shares a PID namespace with a supervisor (see PLAN §2.1).
            '';
          };
          extraServiceConfig = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            description = "Escape hatch, merged last into every jailed unit's serviceConfig.";
          };
        };
      };
    }
  );

  # Rows whose jailed service reads its OWN secrets out of /run/secrets at runtime
  # (extraConfigFiles, $__file{}, credentials_file, APP_KEY_FILE - not LoadCredential)
  # cannot carry the blanket /run/secrets mask without crashing at startup: the mask
  # hides the very files the unit must open. Such rows keep only the docker-surface
  # mask and rely on per-secret `owner = <service uid>, mode = 0400` declarations for
  # cross-service confidentiality. Safe exactly while the jailed units run as their
  # own non-root uid (asserted via jailUser); a unit with a root process inside the
  # jail must instead relocate its secrets out of /run/secrets (see the firefly row).
  ownSecretsMask = ["/run/docker.sock" "/var/lib/docker"];

  # Fleet table, mirroring LIMITS/PORTS: enable=false by default, hosts flip it. Specs are the
  # §2.2 "Data tier" assignments; anything whose runtime paths I cannot verify offline is left
  # disabled with a TODO rather than shipped half-spec'd.
  table =
    {
      postgresql = {
        units = ["postgresql"];
        # Dial-out to nobody: the TCP scram clients (MAS, roundcube) are INBOUND to postgres;
        # replication would need this widened.
        publicDefault = "deny";
        allowDns = false;
        note = "unix-socket DB server: zero new outbound flows; responses ride conntrack.";
      };
      matrixSynapse = {
        units = ["matrix-synapse"];
        # opens sops.templates."synapse-secrets.yaml" (its extraConfigFiles) at startup.
        inaccessiblePaths = ownSecretsMask;
        note = "federation/media fetch = public 443; DB via unix socket; tailnet/LAN blocked.";
      };
      matrixMas = {
        units = ["matrix-mas"];
        # its whole config IS a sops template under /run/secrets, plus key/secret files.
        inaccessiblePaths = ownSecretsMask;
        allowedLoopbackTCPPorts = [
          (config.PORTS.synapse or 8008)
          (config.PORTS.matrixCompat or 8096)
          # MAS is the one DB client that reaches Postgres over TCP loopback (scram) - see
          # modules/services/postgresql.nix pg_hba: the host 127.0.0.1 scram lines exist for it.
          5432
        ];
        note = "MAS drives Synapse over loopback; upstream OIDC = public 443.";
      };
      homepage = {
        units = ["homepage-dashboard"];
        # {{HOMEPAGE_FILE_*}} widgets read their (uid-owned) secret files at startup.
        inaccessiblePaths = ownSecretsMask;
        allowedLoopbackTCPPorts = [
          (config.PORTS.grafana or 8030)
          (config.PORTS.prometheus or 8009)
          (config.PORTS.traefikDashboard or 8888)
          (config.PORTS.transmissionRpc or 8001)
          (config.PORTS.fireflyIii or 8093)
          (config.PORTS.litellm or 8095)
        ];
        note = "widget backends on loopback; external widgets (weather/stocks) need public 443.";
      };
      searx = {
        units = ["searx"];
        note = "engines are the public internet by definition; redis is a unix socket; tailnet/LAN blocked.";
      };
      trilium = {
        units = ["trilium"];
        note = "sync clients connect IN; only update-check dials out; tailnet/LAN blocked.";
      };
      prometheus = {
        units = ["prometheus"];
        # authorization.credentials_file (litellm scrape) is read by the prometheus uid.
        inaccessiblePaths = ownSecretsMask;
        allowAnyLoopback = true;
        # Scrapes node/zfs/tailscale exporters on every fleet host over the tailnet; alerting
        # would add a loopback hop when Alertmanager lands.
        allowTailnet = true;
        publicDefault = "deny";
        allowDns = false;
        note = "scrape targets are tailnet IPs; nothing else.";
      };
      loki = {
        units = ["loki"];
        # nixpkgs' loki unit ships ProtectSystem="full" and no StateDirectory; its
        # chunks/index/compactor tree under /var/lib/loki must be named for "strict".
        readWritePaths = ["/var/lib/loki"];
        # dskit's memberlist enumerates interfaces over NETLINK_ROUTE sockets; without
        # AF_NETLINK loki dies milliseconds into start with "no useable address found
        # for interfaces [eth0 en0]" (proven live on akos01 boot, 2026-10-25 deploy).
        hardening = {
          restrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
        };
        publicDefault = "deny";
        allowDns = false;
        note = "promtail pushes IN (conntrack); Loki itself dials nobody.";
      };
      grafana = {
        units = ["grafana"];
        # secret_key/admin_password reach the unit as $__file{...} inside grafana.ini,
        # which the grafana uid reads at startup.
        inaccessiblePaths = ownSecretsMask;
        # nixpkgs' grafana unit has no StateDirectory - its data dir (/var/lib/grafana,
        # sqlite + the conf/tools symlinks its preStart writes) is writable only because
        # the unit ships ProtectSystem="full". The jail forces "strict", so name it.
        readWritePaths = ["/var/lib/grafana"];
        allowedLoopbackTCPPorts = [
          (config.PORTS.prometheus or 8009)
          (config.PORTS.loki or 8031)
        ];
        note = "datasources on loopback; public 443 stays open for update/geoip checks; tailnet/LAN blocked.";
      };
      syncthing = {
        units = ["syncthing"];
        # nixpkgs' syncthing unit has no StateDirectory either - /var/lib/syncthing is
        # both config dir and DB home, and the main process writes it. (The sops cert/key
        # files stay readable to the jail despite the blanket mask because nixpkgs copies
        # them into the config dir from a root `+`-prefixed ExecStartPre, which runs
        # OUTSIDE the unit's namespaces.)
        readWritePaths = ["/var/lib/syncthing"];
        allowTailnet = true;
        # go-safetynet's network monitor lists interfaces over netlink every 30 min;
        # without AF_NETLINK it logs "route ip+net: netlinkrib: address family not
        # supported" (seen live on akos01, 2026-10-25) - harmless but it poisons the
        # Coroot "Errors in logs" panel for syncthing, so grant it like loki.
        hardening = {
          restrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
        };
        note = "fleet replication rides the tailnet; public relays/listeners; LAN blocked.";
      };
      transmission = {
        units = ["transmission"];
        note = "DHT/peers are public by design; the jail's real job is blocking the tailnet/LAN.";
      };
      firefly = {
        units = [
          "phpfpm-firefly-iii"
          "firefly-iii-cron"
        ];
        # nixpkgs' module grants StateDirectory/ReadWritePaths only to its oneshot
        # units (commonServiceConfig); the fpm pool is a services.phpfpm.pools entry
        # out of reach, and it writes file-backed sessions AND the default file cache
        # under the data dir on EVERY request (SESSION_DRIVER/CACHE_DRIVER unset ->
        # "file"). The jail forces "strict", so name the tree - same trap as the
        # loki/grafana/syncthing rows above; without it the web UI 500s on login.
        readWritePaths = ["/var/lib/firefly-iii"];
        # The php-fpm master runs as root; the pool workers (and the cron unit) drop to the
        # pool user - uid-owner matching needs it spelled out, not read off the unit.
        user = "firefly-iii";
        # Blanket /run/secrets mask KEPT (a root process lives in this jail): APP_KEY_FILE
        # is relocated to /run/jail-secrets/firefly-iii/app-key in firefly-iii.nix. It is
        # opened as the pool user by nixpkgs' setup/`artisan config:cache` (which bakes
        # the key into /var/lib/firefly-iii - the workers read that config cache, not the
        # file), and gets a per-file auditd read-watch via audit.nix's secretReadRules.
        note = "DB via unix socket; exchange-rate providers = public 443; tailnet/LAN blocked.";
      };
      vaultwarden = {
        units = ["vaultwarden"];
        publicDefault = "deny";
        allowDns = false;
        note = "self-hosted vault dials out to nobody (§2.2: 'no internet egress at all'); clients come IN.";
      };
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
        units = [n];
        allowedLoopbackTCPPorts = [(config.PORTS.synapse or 8008)];
        note = "bridge talks to its network's servers (public) and Synapse (loopback); tailnet/LAN blocked.";
      }
    );

  # The effective row: table defaults overlaid with whatever this host contributed. The host
  # definition is merged with the table default by the module system when the option is a
  # whole-submodule option, but hosts write it as `MODULES.security.jails = { x.enable = true;
  # }` - which can arrive as a partial attrset on some evaluation paths, so overlay it on the
  # table row instead of trusting it whole.
  # Per-row defaults (kept OUT of jailType: every jailType field defaults to null so the
  # three-way merge below can tell "host didn't say" from "host said").
  rowDefaults = {
    enable = false;
    backend = "jail";
    user = null;
    noEgress = false;
    readWritePaths = [];
    bindPaths = [];
    bindReadOnlyPaths = [];
    inaccessiblePaths = [
      "/run/secrets.d"
      "/run/secrets"
      "/run/docker.sock"
      "/var/lib/docker"
    ];
    allowedLoopbackTCPPorts = [];
    allowDns = true;
    allowAnyLoopback = false;
    publicDefault = "allow";
    allowPublicTCPPorts = [];
    allowTailnet = false;
    allowLan = false;
    custom = [];
    note = "";
    hardening = {
      noNewPrivileges = true;
      privateTmp = true;
      restrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      restrictSuidSgid = true;
      protectKernelModules = true;
      protectKernelTunables = true;
      privatePIDs = false;
      extraServiceConfig = {};
    };
  };

  # rowDefaults // table row // host row - field-by-field, host `null` (never set) falling
  # through. `or null` per field so a sparse host instance never type-checks its missing
  # options, and the never-forced `when`-style function fields stay safe.
  rowOf = name: let
    t = table.${name} or {};
    # A table row that touches `hardening` must PATCH it, not replace the whole block:
    # strip the row's hardening from the wholesale //, then merge it onto
    # rowDefaults.hardening so untouched keys keep their defaults (the loki AF_NETLINK
    # row relies on this).
    base =
      (rowDefaults // builtins.removeAttrs t ["hardening"])
      // {hardening = rowDefaults.hardening // (t.hardening or {});};
    over = cfg.${name} or {};
    hard = base.hardening // lib.filterAttrs (_: v: v != null) (over.hardening or {});
    merged =
      builtins.foldl' (
        acc: f: let
          v = over.${f} or null;
        in
          if v == null
          then acc
          else acc // {${f} = v;}
      )
      base (builtins.attrNames rowDefaults);
  in
    merged // {hardening = hard;};

  active = lib.filterAttrs (_: j: j.enable) (lib.mapAttrs (n: _: rowOf n) table);

  jailUser = name: j:
  # `j.user` is ALWAYS present (null = auto) after the rowDefaults overlay - test the value,
  # don't `or` the key.
    if (j.user or null) != null
    then j.user
    else (config.systemd.services.${builtins.head j.units}.serviceConfig or {}).User or null;

  chainScript = name: j: let
    chain = chainOf name;
    user = jailUser name j;
    i = "iptables -w";
    rejects =
      (lib.optionals (!j.allowLan) [
        privateRanges.lan
        privateRanges.lan2
        privateRanges.lan3
      ])
      ++ (lib.optionals (!j.allowTailnet) [privateRanges.tailnet])
      ++ [privateRanges.linklocal];
  in
    ''
      # jail-${name} egress (${user}): §3.4 - every deny is LOGged (rate-limited 6/min)
      ${i} -N ${chain} 2>/dev/null || ${i} -F ${chain}
      ${i} -C OUTPUT -m owner --uid-owner ${user} -j ${chain} 2>/dev/null \
        || ${i} -I OUTPUT -m owner --uid-owner ${user} -j ${chain}
      ${i} -A ${chain} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
      ${optionalString j.allowDns ''
        ${i} -A ${chain} -p udp --dport 53 -j RETURN
        ${i} -A ${chain} -p tcp --dport 53 -j RETURN
      ''}
      ${concatMapStringsSep "\n" (p: "${i} -A ${chain} -d 127.0.0.1 -p tcp --dport ${toString p} -j RETURN") j.allowedLoopbackTCPPorts}
      ${optionalString j.allowAnyLoopback "${i} -A ${chain} -d ${privateRanges.loopback} -j RETURN"}
      ${concatMapStringsSep "\n" (r: lib.replaceString "%c" chain r) j.custom}
    ''
    + optionalString (j.publicDefault == "deny") ''
      ${concatMapStringsSep "\n" (p: "${i} -A ${chain} ! -d 127.0.0.0/8 -p tcp --dport ${toString p} -j RETURN") j.allowPublicTCPPorts}
      ${i} -A ${chain} -m limit --limit 6/min -j LOG --log-prefix "egress-deny-${sanitize name}: "
      ${i} -A ${chain} -j REJECT --reject-with icmp-port-unreachable
    ''
    # Allow mode ONLY: in deny mode the blanket LOG+REJECT above already catches every
    # destination, and per-range rules appended BEHIND a blanket REJECT are unreachable
    # dead rules whose counters would forever read zero (2026-10-25 review nit).
    + optionalString (j.publicDefault == "allow") (concatMapStringsSep "\n" (
        r: ''
          # The LOG carries the same -d match as the REJECT: a flow destined elsewhere
          # must not be logged as denied (public flows in allow-mode fall off the chain's
          # end and are accepted - logging them "egress-deny" would page on normal traffic).
          ${i} -A ${chain} -d ${r} -m limit --limit 6/min -j LOG --log-prefix "egress-deny-${sanitize name}: "
          ${i} -A ${chain} -d ${r} -j REJECT
        ''
      )
      rejects);

  stopScript = name: j: let
    chain = chainOf name;
    user = jailUser name j;
  in
    # hermes pattern: never blanket-D with a missing chain; every step is idempotent.
    ''
      iptables -w -D OUTPUT -m owner --uid-owner ${user} -j ${chain} 2>/dev/null || true
      iptables -w -F ${chain} 2>/dev/null || true
      iptables -w -X ${chain} 2>/dev/null || true
    '';

  # Plain attrset (no mkMerge/mkIf inside): folded per unit across jails, then wrapped in a
  # single mkIf at the `serviceConfig` option level - one definition per option per module,
  # the only shape that merges predictably.
  hardeningValue = name: j: let
    h = j.hardening;
  in
    {
      # mkForce, not mkOptionDefault: inside serviceConfig's FREEFORM attrs the inner
      # override wrappers of a plain-priority competing definition (e.g. grafana's own
      # ProtectSystem="full") beat mkOptionDefault empirically on 26.05 - the jail must be
      # authoritative anyway. A host that wants to loosen one of these on a jailed unit
      # disables the jail instead (`jails.<n>.enable = false`); the two mkForce's would
      # surface as a legible conflict, never as a silent "full".
      ProtectSystem = lib.mkForce "strict";
      NoNewPrivileges = lib.mkForce h.noNewPrivileges;
      PrivateTmp = lib.mkForce h.privateTmp;
      RestrictSUIDSGID = lib.mkForce h.restrictSuidSgid;
      ProtectKernelModules = lib.mkForce h.protectKernelModules;
      ProtectKernelTunables = lib.mkForce h.protectKernelTunables;
      ReadWritePaths = j.readWritePaths;
      BindPaths = j.bindPaths;
      BindReadOnlyPaths = j.bindReadOnlyPaths;
      InaccessiblePaths = map (x: "-${x}") j.inaccessiblePaths;
    }
    // lib.optionalAttrs (h.restrictAddressFamilies != null) {
      RestrictAddressFamilies = lib.mkForce h.restrictAddressFamilies;
    }
    // lib.optionalAttrs h.privatePIDs {
      PrivatePIDs = lib.mkForce true;
    }
    // h.extraServiceConfig;
in {
  options = {
    MODULES.security.jails = mkOption {
      type = types.attrsOf jailType;
      default = {};
      description = ''
        Per-service containment specs (Tier A jail now, microVM later) - PLAN.md §2.
        Override fields of a fleet-table row per host with dotted assignments, e.g.
        MODULES.security.jails.postgresql.publicDefault = "allow"; - the merge is
        rowDefaults // table row // host row (host nulls fall through). New jail names
        must be added to the table in this file: generated config keys are static by
        design (see the recursion note in the config block).
      '';
    };
  };

  config = mkMerge [
    # Unit hardening. One gated DEFINITION per unit: `mkIf` sits at the root of the returned
    # attrset so a disabled jail contributes nothing at all. The previous shape
    # (`systemd.services.${u}.serviceConfig = mkIf cond {...}`) marked the unit instance as
    # declared even when every jail touching it was disabled, spawning empty ghost unit
    # stubs for other hosts' services (phpfpm-firefly-iii.service on akos01) - the exact
    # landmine modules/system/limits.nix documents; same fix, same pattern. Flags merge
    # predictably only at option level, so multiple jails on one unit fold into a single
    # value BEFORE the gate (recursiveUpdate across the unit's enabled rows).
    (mkMerge (
      lib.mapAttrsToList (
        u: names:
          mkIf (lib.any (n: (rowOf n).enable && (rowOf n).backend == "jail") names) {
            systemd.services.${u}.serviceConfig =
              lib.foldl' (
                acc: n: let
                  j = rowOf n;
                in
                  if j.enable && j.backend == "jail"
                  then recursiveUpdate acc (hardeningValue n j)
                  else acc
              ) {}
              names;
          }
      ) (
        lib.foldl' (
          acc: pair:
            lib.foldl' (
              rest: u: rest // {${u} = (acc.${u} or []) ++ [pair.name];}
            )
            acc
            pair.units
        ) {} (
          map (n: {
            name = n;
            units = (table.${n} or {}).units or [];
          }) (builtins.attrNames table)
        )
      )
    ))

    (mkIf (builtins.length (builtins.attrNames active) > 0) {
      networking.firewall = {
        extraCommands = concatMapStringsSep "\n" (n: chainScript n active.${n}) (
          lib.attrNames (lib.filterAttrs (_: j: !j.noEgress) active)
        );
        extraStopCommands = concatMapStringsSep "\n" (n: stopScript n active.${n}) (
          lib.attrNames (lib.filterAttrs (_: j: !j.noEgress) active)
        );
      };
    })

    {
      assertions =
        (lib.mapAttrsToList (name: j: {
            assertion = !(j.enable && j.backend == "microvm");
            message = ''
              MODULES.security.jails.${name}.backend = "microvm" is declared but mkServiceVM
              (PLAN.md §6) is not wired yet - refusing to run ${name} UNcontained. Flip the
              backend back to "jail" (the spec carries over unchanged) or wait for §6.
            '';
          })
          active)
        ++ (lib.mapAttrsToList (name: j: {
            assertion = j.noEgress || (jailUser name j) != null;
            message = ''
              MODULES.security.jails.${name}: cannot resolve the jail user - set `user`, or
              make sure the unit ${builtins.head j.units} exists on this host with User= set
              (the egress chain needs a uid to match on).
            '';
          })
          active)
        ++ (lib.mapAttrsToList (name: j: {
            assertion = builtins.stringLength (chainOf name) <= 28;
            message = "MODULES.security.jails.${name}: iptables chain name >28 chars is silently truncated by iptables - rename the jail.";
          })
          cfg)
        ++ [
          (
            let
              allUnits = builtins.concatLists (map (j: j.units) (builtins.attrValues active));
            in {
              assertion = builtins.length allUnits == builtins.length (lib.unique allUnits);
              message = "Two enabled MODULES.security.jails rows claim the same systemd unit.";
            }
          )
        ];
    }
  ];
}
