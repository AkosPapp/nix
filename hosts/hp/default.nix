{
  config,
  pkgs,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  # Other hosts' Traefik zones (by default their host name: legion5, akos01, ...) and the Tailscale IP
  # behind each. Generated from the flake, so a new host needs no edit here.
  tailnetZones = lib.filter (z: z.ip != null) (lib.mapAttrsToList (host: h: {
    domain = h.config.MODULES.networking.traefik.domain;
    ip = h.config.MODULES.networking.tailscale.hostIP;
  }) (lib.removeAttrs nixosConfigurations [configName]));

  # dnsmasq's dynamic include, regenerated on a timer. While tailscale is connected, its zone
  # (MagicDNS) is forwarded and every other host's zone resolves to that host's tailscale IP.
  # robo4you.at points at r4uai01's netbird IP only while its route leaves through wt0 and it
  # answers the zone; otherwise none of those lines exist and dnsmasq falls through to the public
  # servers. The file is only replaced (and dnsmasq restarted) when its contents change.
  splitDns = pkgs.writeShellScript "split-dns" ''
    export PATH="${lib.makeBinPath [
      config.systemd.package
      config.services.tailscale.package
      config.services.netbird.package
      pkgs.coreutils
      pkgs.jq
      pkgs.iproute2
      pkgs.dnsutils
      pkgs.diffutils
    ]}"

    conf=/run/dnsmasq.d/split.conf
    mkdir -p "$(dirname "$conf")"

    netbird_dns=100.124.160.88
    netbird_zone=robo4you.at

    # tailscale0 survives `tailscale down`, so ask the backend instead of the interface.
    tailscale_up=0
    if ip link show dev tailscale0 up >/dev/null 2>&1; then
      state=$(timeout 2 tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') || state=
      if [ "$state" = "Running" ]; then
        tailscale_up=1
      fi
    fi

    # wt0 having an address proves nothing: the daemon can sit disconnected for hours with the
    # interface left in place, and every query dnsmasq forwards into it blackholes - including
    # netbird's own lookup of its management host, which turns one dropout into a permanent
    # lockout. Ask the daemon instead: connected to Signal AND at least one relay available or
    # one peer connected (peers legitimately sit Idle on a lazy mesh, so relays carry most of
    # the "data plane alive" vote). Only then the zone probe still has to answer.
    netbird_up=0
    if ip link show dev wt0 up >/dev/null 2>&1; then
      nb=$(timeout 3 netbird status --json 2>/dev/null | jq -r \
        '[.signal.connected // false, (.relays.available // 0), (.peers.connected // 0)] | @tsv') || nb=
      case "$nb" in
        true*)
          route=$(ip route get "$netbird_dns" 2>/dev/null) || route=
          case " $route " in
            *" dev wt0 "*)
              relays=$(cut -f2 <<<"$nb")
              peers=$(cut -f3 <<<"$nb")
              if [ "$relays" -gt 0 ] 2>/dev/null || [ "$peers" -gt 0 ] 2>/dev/null; then
                if [ -n "$(dig +time=1 +tries=3 +short "@$netbird_dns" "$netbird_zone" SOA 2>/dev/null)" ]; then
                  netbird_up=1
                fi
              fi
              ;;
          esac
          ;;
      esac
    fi

    {
      if [ "$tailscale_up" = 1 ]; then
        echo "server=/${config.MODULES.networking.tailscale.tailnetDnsName}/100.100.100.100"
        ${lib.concatMapStringsSep "\n    " (z: "echo 'address=/${z.domain}/${z.ip}'") tailnetZones}
      fi
      if [ "$netbird_up" = 1 ]; then
        echo "server=/$netbird_zone/$netbird_dns"
      fi
      # The tunnel must never have to resolve its own front door: robo4you.at routes into
      # netbird, so netbird.robo4you.at gets a permanent longest-match exception to the public
      # resolvers - emitted whether or not the zone line is present, so netbird's bootstrap
      # lookup can never depend on the connection it needs that lookup to establish.
      echo "server=/netbird.$netbird_zone/9.9.9.9"
      echo "server=/netbird.$netbird_zone/1.1.1.1"
    } > "$conf.new"

    if ! cmp -s "$conf.new" "$conf"; then
      mv "$conf.new" "$conf"
      systemctl restart dnsmasq
    else
      rm -f "$conf.new"
    fi
  '';

  # The timer below is the backstop; this is the fast path. `ip monitor` streams the same
  # netlink events udev sees, so a VPN interface, address or route landing (netbird's wt0,
  # tailscale's routes flushed on down) wakes the updater within ~1s instead of up to a poll
  # interval plus script runtime. One burst of events (a reconnect flaps several routes)
  # collapses to a single updater run, and `systemctl start` waits for it, serialising runs.
  splitDnsWatch = pkgs.writeShellScript "split-dns-watch" ''
    export PATH="${lib.makeBinPath [
      pkgs.iproute2
      config.systemd.package
      pkgs.coreutils
    ]}"
    while IFS= read -r _; do
      # Give whoever changed the network a beat to finish, drain the rest of the burst, then trigger.
      sleep 1
      while IFS= read -r -t 1 _; do :; done
      systemctl start split-dns.service || true
    done < <(exec ip monitor link address route)
  '';

  # PDF and JSON tooling for the Hermes agent, its cron jobs, and root's shell.
  # enableLanguages must be pinned: the tesseract wrapper's default is *every*
  # language (~1 GB of traineddata). eng is mandatory alongside (tessdata bug).
  agentTools = with pkgs; [
    poppler-utils # pdftotext, pdfimages, pdfinfo (attr renamed from poppler_utils)
    pdfgrep
    jq
    (tesseract.override {enableLanguages = ["eng" "deu"];}) # scanned-PDF OCR, German
    # This nixpkgs' plain ffmpeg is the full build (libx264/x265, freetype/drawtext),
    # verified against the locked flake's derivation - no need for ffmpeg-full here.
    ffmpeg
  ];
in {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  # hp runs unattended (no physical access path except tailscale): restart tailscaled
  # when it hangs offline (4 probes * 90 s), so a wedged session can't orphan it again.
  MODULES.networking.tailscale.watchdog.enable = true;
  # Nightly: pull litellm/omniroute/trilium images, recreate a container only when its
  # image actually changed (docker-images-update.nix).
  MODULES.virtualisation.docker-images-update.enable = true;
  MODULES.services.syncthing.deviceID = "ST66PS2-5LYQY5J-LNI3FR4-3VLG7W3-F4ZHRS2-72NZMBG-QVWV2QD-6SB2DQF";
  # The notes graph, down here so the Hermes agent can read it. `path` stays legion5's path on
  # purpose: that string is the Syncthing folder ID *and* the peer-matching key (see
  # MODULES.services.syncthing.shares), which is what wires hp into the folder legion5 and the phone
  # already share. `override_path` is where hp keeps it. The phone is a direct peer too, so notes
  # arrive even while legion5 is switched off.
  MODULES.services.syncthing.shares = [
    {
      path = "/home/akos/notes";
      override_path = "/var/lib/notes";
      # copyOwnershipFromParent deliberately NOT set: it makes syncthing lchown pulled files to
      # the parent dir's owner:group, which an unprivileged syncthing cannot do into a group it is
      # not a member of (syncthing must never join `hermes`) -> every finalize fails with
      # "copy owner from parent: lchown: invalid argument" and the folder retries forever. The
      # 2755 setgid bit below already gives new files group=hermes through kernel inheritance,
      # which is all the agent's read access needs.
      extra_devices = ["phone"];
      # git stays on legion5; hp only wants the markdown. Ignore patterns are per-device, so this
      # doesn't change what legion5 and the phone exchange with each other.
      ignorePatterns = ["/.git"];
    }
  ];
  # hp's syncthing already runs as the `syncthing` uid for the grafana/prometheus shares, so the
  # notes folder goes next to those instead of under /var/lib/hermes: reaching a share inside
  # /var/lib/hermes would mean either the hermes group (2770 = *group writable*, so a network-facing
  # daemon could delete the agent's own state) or an execute-only POSIX ACL, which this ZFS dataset
  # does not support. It is world-readable for the same reason dashboardsDir is: the agent runs in a
  # user namespace, where foreign uids show up as nobody and only the `other` bits carry.
  systemd.tmpfiles.rules = [
    # dnsmasq's dynamic include directory, written by the split-dns service below.
    "d /run/dnsmasq.d 0755 root root -"
    "d /var/lib/notes 2755 syncthing hermes - -"
    # The agent's own note folder (inside the share, so its notes sync like any other file).
    # The 2775 is the whole scope of its write access: every other directory in the share stays
    # 2755, so outside hermes/ the agent can create or replace nothing.
    "d /var/lib/notes/hermes 2775 syncthing hermes - -"
  ];
  # Per-session escalation for the whole share, run by hand as root - the agent has no root in
  # its sandbox and must not gain any: broad write access then exists only between an explicit
  # `grant` and the next `revoke`, and a reboot reasserts the tmpfiles modes anyway. No rebuild
  # involved, so it works while a chat session is live.
  environment.systemPackages =
    [
      (pkgs.writeShellScriptBin "hermes-notes-edit" ''
        set -eu

        if [ "$#" -lt 1 ]; then
          echo "usage: hermes-notes-edit grant|revoke|status" >&2
          exit 2
        fi

        # Everything in the share except syncthing's own state.
        walk() {
          find /var/lib/notes -not -path '*/.stfolder*' -not -name '.stignore' "$@"
        }

        case "$1" in
          grant)
            # g+w on directories lets the agent replace files; on files, edit them in place.
            # New folders synced in afterwards need another grant pass (status shows the damage).
            walk -type d -exec chmod g+w '{}' +
            walk -type f -exec chmod g+w '{}' +
            echo "granted: hermes can edit every file in the notes share"
            ;;
          revoke)
            walk -type d -exec chmod 2755 '{}' +
            walk -type f -exec chmod 644 '{}' +
            chmod 2775 /var/lib/notes/hermes
            echo "revoked: back to the agent's own hermes/ folder only"
            ;;
          status)
            if walk -mindepth 1 -type d -not -path '/var/lib/notes/hermes*' -perm -g+w | grep -q .; then
              echo "GRANTED: group-writable beyond hermes/:"
              walk -mindepth 1 -type d -perm -g+w
            else
              echo "locked: agent writes limited to /var/lib/notes/hermes"
            fi
            ;;
          *)
            echo "usage: hermes-notes-edit grant|revoke|status" >&2
            exit 2
            ;;
        esac
      '')
    ]
    ++ agentTools;
  # The agent's sandbox sees /var/lib/hermes and nothing else, so bind the share into it. The two
  # Hermes units get it read-write at the mount, but write access is carried by the file modes
  # instead: 2755 everywhere except /var/lib/notes/hermes (2775), so the kernel denies the agent
  # create/replace/delete anywhere else while `hermes-notes-edit grant` (above) can still widen it
  # for one session without a restart. matrix-reader keeps the hard read-only bind - it only ever
  # reads notes. The `-` prefix keeps the units up if the folder is ever missing.
  #
  # One agent-side rule this trades away nothing on but cannot be enforced by modes: the units run
  # UMask=0077, so a file the agent writes is 0600 and syncthing, reading as `other`, would never
  # see it. The agent's notes workflow chmods its own files 644 as it writes them.
  systemd.services = let
    notes-bind = "-/var/lib/notes:/var/lib/hermes/notes";
  in {
    # The Hermes units run with a closed PATH; environment.systemPackages is NOT in
    # it, so every tool the agent's terminal() or cron shells may execute has to be
    # listed on the unit itself (the systemd module appends these to the unit PATH).
    hermes-agent.path = agentTools;
    hermes-backend.path = agentTools;
    hermes-agent.serviceConfig.BindPaths = [notes-bind];
    hermes-backend.serviceConfig.BindPaths = [notes-bind];
    matrix-reader.serviceConfig.BindReadOnlyPaths = [notes-bind];

    # /var/lib/pgdump should be the zfs dataset zroot/persist/hp/dump (that is what makes
    # the logical dump ride the L2 push to akos01). PLAN's manual `zfs create` before the
    # first 00:05 timer becomes this idempotent pre-start instead: tmpfiles creates the
    # mountpoint empty at boot, the dataset lands on the empty dir at first use, later
    # runs no-op. The leading "-" is systemd's ignore-failure marker (dataset exists /
    # dir busy), so no shell is needed; if the dir ever holds files before the dataset
    # exists, create fails soft and dumps keep writing to the plain dir - same as before,
    # just visible via `zfs list` when checked.
    znapzend-pg-dump.serviceConfig.ExecStartPre = "-${pkgs.zfs}/sbin/zfs create -o mountpoint=/var/lib/pgdump zroot/persist/hp/dump";

    split-dns = {
      description = "Regenerate dnsmasq's VPN-dependent split-DNS include";
      # A transient dnsmasq restart failure must not stop the timer from retrying.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${splitDns}";
      };
    };

    split-dns-watch = {
      description = "Trigger split-dns immediately on interface/address/route changes";
      wantedBy = ["multi-user.target"];
      # `ip monitor` can die on a netlink buffer overrun; never let the start-limit give up on it.
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${splitDnsWatch}";
        Restart = "always";
        RestartSec = "2s";
      };
    };
  };
  # One local resolver (dnsmasq) instead of systemd-resolved, because the split depends on
  # whether each VPN is actually usable:
  # - public backups, in the requested order: 9.9.9.9, 1.1.1.1, 8.8.8.8
  # - AirLab's DNS only for its zone (the DHCP-provided servers are otherwise ignored)
  # - Tailscale's MagicDNS and the other hosts' Traefik zones only while tailscale is connected
  # - robo4you.at via netbird's r4uai01 (100.124.160.88) only while wt0 is up, the route to it
  #   leaves through wt0, and it answers the zone. netbird's DNS client is disabled in
  #   users/akos.nix.
  # The dynamic parts come from splitDns above; dnsmasq is restarted only when its include
  # actually changes.
  services.resolved.enable = false;

  services.dnsmasq = {
    # modules/networking/dns.nix already runs this host's authoritative zone in dnsmasq and
    # deliberately keeps it off the system resolver; here we also want it to be the system
    # resolver, and to keep listening on the tailscale address for the authoritative zone.
    resolveLocalQueries = lib.mkForce true;
    settings = {
      # Never adopt the DHCP servers as defaults: the public list below is the fallback.
      no-resolv = lib.mkForce true;
      # `no-resolv` already ignores this; drop the module's marker to avoid a startup warning.
      resolv-file = lib.mkForce [];
      # The tailscale address may not exist yet when dnsmasq starts.
      bind-dynamic = lib.mkForce true;
      listen-address = lib.mkForce [
        "127.0.0.1"
        "::1"
        config.MODULES.networking.tailscale.hostIP
      ];
      strict-order = true;
      server = [
        "9.9.9.9"
        "1.1.1.1"
        "8.8.8.8"
        "/airlab/10.50.20.2"
      ];
      conf-dir = "/run/dnsmasq.d,*.conf";
    };
  };

  systemd.timers.split-dns = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5s";
      OnUnitActiveSec = "10s";
    };
  };

  # Tailscale still provides the tailnet; dnsmasq forwards its zone explicitly.
  services.tailscale = {
    # dnsmasq owns the system resolver, so tailscaled must not manage resolv.conf.
    extraSetFlags = lib.mkForce [
      "--accept-dns=false"
      "--accept-routes=true"
      "--advertise-exit-node=true"
    ];
    useRoutingFeatures = "both";
  };
  networking.enableIPv6 = false;

  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;
  MODULES.security.sops.enable = true;
  # No X11 / ssh-agent auth on a server (2026-10-24 audit #8): nobody graphs onto hp, and a
  # forwarded agent is every key it holds. The laptop (legion5) keeps both.
  MODULES.networking.sshd.x11Forwarding = false;
  MODULES.networking.sshd.agentAuth = false;
  # MODULES.system.printing.enable = true;
  # services.printing.openFirewall = true;
  # services.printing.listenAddresses = [
  #   "127.0.0.1:${toString config.PORTS.cups}"
  #   "${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.cups}"
  # ];
  # services.printing.allowFrom = ["all"];
  # MODULES.networking.traefik.services.cups = "127.0.0.1:${toString config.PORTS.cups}";

  MODULES.networking.traefik.enable = true;
  # The public face on akosp.app: a Cloudflare Tunnel whose single wildcard ingress lands on
  # Traefik's loopback `cloudflare` entry point, plus a oneshot that keeps the zone's records
  # pointed at the tunnel through the Cloudflare API (a name appears in DNS exactly when it has
  # a route - matrix.nix is the first consumer, see the `public` options there). TLS is
  # Cloudflare's Universal SSL at their edge; no public port opens here, and unlike the Funnel
  # (RUNBOOK-public.md) this is the real domain, so clients like Matrix federation work.
  # Secrets and the one-time tunnel creation: RUNBOOK-cloudflare.md / `nix run .#cloudflare-config`.
  # Created 2026-10-24 with the setup app flow (tunnel `hp`, CNAMEs akosp.app + m.akosp.app
  # routed, credentials + cert.pem in sops).
  MODULES.networking.dns.cloudflare = {
    enable = true;
    domain = "akosp.app";
    tunnel.uuid = "c5955163-d4b6-4f01-9d60-bb33a57910b8";
  };
  MODULES.services.homepage.enable = true;
  MODULES.services.firefly-iii.enable = true;
  MODULES.services.grafana.enable = true;
  MODULES.services.loki.enable = true;
  # hp is the CPU worker as well as the gateway: it serves catalogue names legion5 also serves, so
  # LiteLLM treats them as replicas of one model and keeps answering - slowly, on four Zen+ cores -
  # while the laptop is shut. Weight 1 against legion5's 8 decides how the traffic splits when both
  # are up.
  #
  # GGUF quants rather than full-precision weights: small-text is a ~2.5 GB Q4_K_M whose q8_0 cache
  # is sized to the configured context, which is what makes 8192 tokens affordable beside Immich
  # ML, Prometheus, Loki, Grafana and Traefik on this 21 GiB machine. One model resident at a time
  # (maxLoadedModels default), two parallel slots each.
  MODULES.services.ollama.enable = true;
  MODULES.services.ollama.models = {
    small-text = {
      source = "qwen3:4b-instruct-2507-q4_K_M";
      contextLength = 16384;
    };
  };

  # hp is the always-on node, so the gateway lives here rather than on the laptop, and it is
  # https://litellm.hp that goes in a client config.
  MODULES.services.litellm.enable = true;
  # Where requests land when the only host serving a name is unreachable. litellm.nix builds those
  # fallbacks for every name no local host has, which is most of legion5's catalogue (coder,
  # gpt-oss, heretic): with the laptop shut they answer from this host's local/small-text instead
  # of erroring. Of the entries here it is the cheap one, and a degraded reply beats a failure.
  MODULES.services.litellm.fallbackModel = "local/small-text";
  # Wildcard OpenRouter passthrough - see litellm.nix. Key comes from the openrouter_api_key sops
  # secret.
  MODULES.services.litellm.openrouterEnable = true;
  # Second gateway, managed from its own dashboard (https://omniroute.hp) rather than
  # declared here: hosted providers and combos live in its database. The first-login password is
  # in /var/lib/omniroute/secrets.env (INITIAL_PASSWORD) - see omniroute.nix.
  MODULES.services.omniroute.enable = true;
  # Wildcard passthrough the other way: OmniRoute's own dashboard-managed providers/combos,
  # reachable through LiteLLM as "omniroute/<name>" - see litellm.nix. omniroute_api_key has to
  # be created by hand from OmniRoute's dashboard first (its module has no sops key to auto-fill
  # - see the option's doc comment), then added to sops under that name.
  MODULES.services.litellm.omnirouteEnable = true;
  MODULES.services.litellm.omnirouteApiKeySecret = "omniroute_api_key";
  # Third gateway, the Aqueduct instance self-hosted at https://futurelab.robo4you.at: wildcard
  # passthrough the same way again, so its models are reachable through LiteLLM as
  # "futurelab/<name>" - see litellm.nix. Nothing about it is on the tailnet, it is reached over
  # the public internet like OpenRouter is, and the models listed are discovered from Aqueduct's
  # own /v1/models, i.e. whatever its dashboard
  # (https://futurelab.robo4you.at/aqueduct/management/) has configured.
  #
  # futurelab_api_key has to be created by hand first, from the Tokens page of that dashboard,
  # since it sits behind the gateway's own login and nothing here can mint one - the same
  # manual-step situation omniroute's key is in.
  MODULES.services.litellm.futurelabEnable = true;
  # The gateway itself, on the internet: https://hp.tail546fb.ts.net:8443/litellm/v1 through the
  # shared Funnel origin (see RUNBOOK-public.md). It exists for the Paseo installers - the machines
  # they install deliberately have no Tailscale, so https://litellm.hp is not an address they can
  # use - and for any other off-tailnet client. Only the OpenAI-compatible prefix gets a route: the
  # admin UI, its management API and /metrics stay tailnet-only, and what is public answers only to
  # a LiteLLM key (litellm_master_key, or a virtual key minted from it). See the `public` options in
  # litellm.nix.
  MODULES.services.litellm.public.enable = true;
  MODULES.services.prometheus.enable = true;
  # 21 GiB box; eval fails if the LIMITS table's MemoryHigh lines stop fitting (PLAN.md §1.2).
  MODULES.system.limits.memoryBudget = "18G";
  # Author the §1.7 PSI-pressure alert rules here; Syncthing ships them to every Prometheus.
  MODULES.system.limits.managePressureRules = true;
  # PLAN.md §2 Tier A + §3.4: per-service containment specs live in modules/security/jail.nix
  # (fleet table, enable=false default); flipped on here only for units that exist on this
  # host with a resolvable jail user (phpfpm/trilium/omniroute run as root today - they need a
  # User= before they can ride the uid-based egress chains). Every deny is LOGged
  # "egress-deny-<jail>: " into journald -> Loki. Flip `backend = "microvm"` per row when §6
  # lands; the spec carries over unchanged.
  MODULES.security.jails.postgresql.enable = true;
  MODULES.security.jails.matrixSynapse.enable = true;
  MODULES.security.jails.matrixMas.enable = true;
  MODULES.security.jails.mautrix-whatsapp.enable = true;
  MODULES.security.jails.mautrix-signal.enable = true;
  MODULES.security.jails.mautrix-slack.enable = true;
  MODULES.security.jails.mautrix-discord.enable = true;
  MODULES.security.jails.mautrix-jabber.enable = true;
  MODULES.security.jails.homepage.enable = true;
  MODULES.security.jails.searx.enable = true;
  MODULES.security.jails.prometheus.enable = true;
  MODULES.security.jails.loki.enable = true;
  MODULES.security.jails.grafana.enable = true;
  MODULES.security.jails.syncthing.enable = true;
  MODULES.security.jails.firefly.enable = true;
  # PLAN §3: auditd + execve keys for the code-running class (hermes IS the agent uid -
  # paseo-hermes shares it; matrix-synapse's tree is static so execve is near-silent) + the
  # journald forwarder + Grafana paging rules. Container workloads run as root's uid and are
  # covered by their jails' egress LOGs, not execve keys.
  MODULES.security.audit.enable = true;
  # PLAN §4: znapzend L1 snapshots + the §4.2 fleet schedule; persist/hp replicates to
  # akos01 (L2) - daemon on the source, destination pruned as part of replication.
  MODULES.system.znapzend = {
    enable = true;
    sshKeySecret = "znapzend/ssh_key_b64";
    # lands on zroot/persist/hp/dump -> rides the recursive push to akos01
    pgDumpDir = "/var/lib/pgdump";
    jobs = [
      {
        dataset = "zroot/root";
        plan = "1d=>1h,2w=>1d,8w=>1w";
      }
      {
        dataset = "zroot/persist/hp";
        plan = "1d=>1h,2w=>1d,8w=>1w";
        destinations.akos01 = {
          host = "root@akos01";
          dataset = "zroot/persist/hp";
        };
      }
      # The laptop replica this box receives: local snapshots only (§4.2 row 3).
      {
        dataset = "zroot/persist/legion5";
        plan = "1d=>1h,2w=>1d,8w=>1w";
      }
    ];
  };
  # PLAN §6: microVM host - prototype guest proves the pipeline before any jail flips
  # backend = "microvm" (jail.nix refuses the flip until the name is in this list).
  MODULES.system.microvmHost = {
    enable = true;
    vms = ["vm-agents"];
  };

  # PLAN §7: east-west service graph in observe mode (log-only) + the passive Suricata
  # tap (hp is the tailnet aggregation point - one tap is enough); flip
  # MODULES.security.serviceGraph.enforce after a week of explainable sg-seen logs
  # (query {unit="kernel"} |= "sg-seen" / {job=~".*suricata.*"} in Loki).
  MODULES.security.serviceGraph = {
    enable = true;
    suricata.enable = true;
    allow = [
      # step-ca issuance arrives over the tailnet from every enrollment (incl. VMs later).
      {
        name = "step-ca";
        ports = [config.PORTS.stepCa];
        from = ["100.64.0.0/10"];
      }
      # znapzend push target is ssh (covered); the laptop replica arrives over tailscale
      # too - nothing extra needed yet, this list is where host-local edges will land.
    ];
  };

  MODULES.security.audit.execUsers = [
    "postgres"
    "hermes"
    "paseo"
    "matrix-synapse"
  ];

  # Coroot observability hub: ClickHouse + Coroot + node-agent (see modules/services/coroot.nix).
  # UI at https://coroot.hp over Tailscale. 2026-10-25: every fleet host gets its own Coroot
  # server; this one visualises hp. akos01 no longer pushes here - it runs its own server
  # (coroot.<akos01's domain>); any future agentEnable-only host would still point HERE.
  # After first start: log in as admin with the one-time password
  # `sudo grep AUTH_BOOTSTRAP_ADMIN_PASSWORD /var/lib/coroot/secrets.env` (root-only, self-deletes
  # after a week), then set the Coroot cluster's logs source to Loki in Settings.
  MODULES.services.coroot.enable = true;

  # n8n, the n8n-sandbox runner and LibreChat were removed from the fleet on 2026-10-24
  # (PLAN.md §1.5) - the chat UIs that remain are Open WebUI and Omniroute's own.

  # Paseo control plane - see hosts/hp/RUNBOOK/RUNBOOK-paseo.md + modules/services/paseo.nix. The hub
  # daemon serves https://paseo.hp (tailnet), the relay is the one public piece (Funnel port
  # 10000), and https://hp.tail546fb.ts.net:8443/install/<token>/{opencode,pi}.sh bootstraps
  # remote harness machines. Secrets: sops paseo/*.
  MODULES.services.paseo.enable = true;
  # Hermes' own Paseo daemon (uid hermes, loopback 8116, dials out to the relay above): drives
  # Hermes conversations from the Paseo app/dashboard via the ACP provider "Hermes". Its egress
  # gets exactly one extra hermes-egress RETURN rule (tailnet IP:10000) - see paseo-hermes.nix.
  # Secret: sops paseo/hermes_daemon_password.
  MODULES.services.paseo-hermes.enable = true;

  # opencode (terminal coding agent) on this host, for root's shell. hp has no akos uid, so the
  # module cannot be reached via users/akos.nix and is enabled here directly, with the API-key
  # secret mounted root:root (secretOwner/secretGroup). What root gets is exactly the interactive
  # setup legion5's akos uses - the package (environment.systemPackages = root's PATH),
  # /etc/opencode.json + $OPENCODE_CONFIG pointing at it, and the same litellm.hp provider,
  # model and sops key restated verbatim from users/akos.nix (repo convention: every consumer
  # restates the catalogue, cf. the paseo-machine block in hosts/legion5/default.nix).
  MODULES.services.opencode = {
    enable = true;
    secretOwner = "root";
    secretGroup = "root";
    defaultModel = "litellm/futurelab/qwen3.8-flash-next";
    smallModel = "litellm/futurelab/qwen3.8-flash-next";
    providers.litellm = {
      displayName = "LiteLLM (hp)";
      baseURL = "https://litellm.hp/v1";
      apiKeySecret = "opencode/litellm_api_key";
      models = {
        "futurelab/qwen3.8-flash-next" = let
          effort = e: {
            chat_template_kwargs = {
              thinking = true;
              reasoning_effort = e;
            };
          };
        in {
          contextLength = 262144;
          outputLength = 32768;
          modalities = {
            input = ["text" "image" "video"];
            output = ["text"];
          };
          options = effort "xhigh";
          variants = {
            # Variants merge over `options`, so "off" has to switch the base thinking flag off too.
            off = {
              enable_thinking = false;
              chat_template_kwargs.thinking = false;
            };
            low = effort "low";
            medium = effort "medium";
            xhigh = effort "xhigh";
          };
          cost = {
            input = 0.0;
            output = 0.0;
            cache_read = 0.0;
            cache_write = 0.0;
          };
        };
      };
    };
    # Backup for when this host's litellm is down (from another machine's point of view): the
    # same model straight from the futurelab Aqueduct gateway, restated verbatim from
    # users/akos.nix. Bare model id on purpose - "futurelab/..." is the LiteLLM wildcard
    # spelling, the Aqueduct gateway lists the name without a prefix.
    providers.futurelab = {
      displayName = "FutureLab (Aqueduct)";
      baseURL = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key";
      models = {
        "qwen3.8-flash-next" = {
          contextLength = 262144;
          outputLength = 32768;
          modalities = {
            input = ["text" "image" "video"];
            output = ["text"];
          };
          options = {
            chat_template_kwargs = {
              thinking = true;
              reasoning_effort = "xhigh";
            };
          };
          variants = {
            off = {
              enable_thinking = false;
              chat_template_kwargs.thinking = false;
            };
            low = {
              chat_template_kwargs = {
                thinking = true;
                reasoning_effort = "low";
              };
            };
            medium = {
              chat_template_kwargs = {
                thinking = true;
                reasoning_effort = "medium";
              };
            };
            xhigh = {
              chat_template_kwargs = {
                thinking = true;
                reasoning_effort = "xhigh";
              };
            };
          };
          cost = {
            input = 0.0;
            output = 0.0;
            cache_read = 0.0;
            cache_write = 0.0;
          };
        };
      };
    };
  };

  # Personal agent stack - see RUNBOOK-hermes.md next to this file for the manual steps (sops
  # secrets, bridge logins, OAuth). The mautrix bridges put WhatsApp, Signal and Slack chats into
  # it; Hermes talks to akos there and can read the bridged rooms it is invited to.
  # Identity is the public domain now: @akos:akosp.app, served at https://m.akosp.app through the
  # Cloudflare Tunnel with federation ON (matrix.nix's `public` options: the m. + apex routes and
  # the .well-known delegations), so other homeservers can reach it. https://matrix.hp stays up on
  # the tailnet for Element and the bridges. Account creation stays closed to everyone: open
  # registration is off, and the only accounts that exist are the ones matrix.nix provisions from
  # sops (akos, hermes). Element stays tailnet-only.
  # The matrix.hp -> akosp.app server_name migration ran as a rooms-wipe (accounts, Mattermost
  # logins, channel attachments and ghost registrations kept; old Matrix-side message copies,
  # which duplicate the networks' own history, were dropped - newer Synapse recomputes v11 event
  # IDs from the event JSON, so a rewritten history can never load). Runbook: RUNBOOK-cloudflare.md.
  MODULES.services.matrix.serverName = "akosp.app";
  MODULES.services.matrix.public.enable = true;
  # One namespace for all Matrix bridges. whatsapp/signal/slack/discord are mautrix
  # appservices (see modules/services/mautrix.nix); Mattermost rides in via matterbridge
  # instead of a second appservice: relay style, one bot user, chats attached with `!mm
  # join` in the control room; its login-as-you credentials come from sops
  # (mattermost/password).
  MODULES.services.matrix = {
    enable = true;
    # MAS delegation: browser/QR logins, per-device tokens, passwordless for humans. Legacy
    # clients (bridges, Hermes) keep working through the compat splitter. Costs double-puppeting
    # and bridge-side E2EE (appservice login is rejected by MAS) - see matrix.nix's mas option.
    mas.enable = true;
    whatsapp.enable = true;
    signal.enable = true;
    slack.enable = true;
    discord.enable = true;
    # XMPP puppeting bridge (jmpchat-matrix-bridge) against the local Prosody below - the one
    # bridge here with Matrix-side E2EE on. Login: DM @jabberbot:akosp.app, "!jabber login".
    jabber.enable = true;
    mattermost = {
      # puppeting bridge: messages appear from the real Mattermost users, and sends appear as me
      # OFF for now: too many bridged channels made Element lag (2026-10-24). Flip back on after
      # the MAS reset once the client can keep up.
      enable = false;
      user = "AkosPapp";
      teams = ["fsinf" "w-inf-tuwien"];
    };
    matterbridge = {
      # relay-style predecessor, replaced by mautrix-mattermost (everything came from one
      # account). Its rooms stay in the database as orphans until pruned by hand; re-enabling
      # this one also requires disabling mattermost above (they would double-relay).
      enable = false;
    };
  };

  # Prosody XMPP server hosting akosp.app (same domain as Matrix; JIDs like akos@akosp.app).
  # Reachability is IPv6-only (hp's IPv4 is NATed): the xmpp module maintains the AAAA at
  # xmpp.akosp.app plus the _xmpp-client/_xmpp-server SRV records through the Cloudflare API
  # token (cloudflare/dns_api_token) and a DNS-01 cert from Let's Encrypt. Accounts come from
  # sops (xmpp/*_password), hashed into Prosody once at first boot. Matrix side: the jabber
  # bridge above. Runbook: RUNBOOK-xmpp.md.
  MODULES.services.xmpp.enable = true;

  MODULES.services.hermes-agent.enable = true;

  # Hermes' calendar, out to the world: a token-gated ICS feed at
  # https://hp.tail546fb.ts.net:8443/ics/<token>/hermes.ics (the token lives in sops as
  # hermes/ics_token) - this is what goes into Google Calendar. It exists because Tailscale's own
  # `serve` cannot: any serve entry makes tailscaled bind 443 on the tailscale IP, which is
  # Traefik's listener, and Traefik then dies at its next restart (this took down every *.hp site
  # once already). The feed file itself is /var/lib/hermes/ics-serve/hermes.ics, rewritten by
  # Hermes' cron job. See hermes-ics.nix.
  MODULES.services.hermes-ics.enable = true;

  # Trilium Notes (https://triliumnotes.org) as the knowledge base - https://trilium.hp on the
  # tailnet. The ETAPI token was created in the UI and stored in sops (trilium/etapi_token), so
  # Hermes reads and writes notes through it (see trilium.nix).
  MODULES.services.trilium.enable = true;
  MODULES.services.trilium.etapiTokenSecret = "trilium/etapi_token";
  # Settings -> AI comes up with this host's LiteLLM as the provider, on the master-key-minted
  # virtual key trilium/litellm_api_key (trilium.nix's `litellm` options for the seeding
  # mechanics and the one-time key creation command).
  MODULES.services.trilium.litellm.enable = true;

  # Outline was tried and dropped - not needed. Its data (Postgres's "outline" database,
  # /var/lib/outline) was removed by hand on the host; see git history for how it was set up if
  # it comes back. mdbook (public docs) is unrelated and stays on.
  MODULES.services.outline.enable = false;

  # Public (Tailscale Funnel -> Traefik's `funnel` entry point) at https://hp.tail546fb.ts.net:8443/mdbook,
  # behind a git.robo4you.at login - see RUNBOOK-public.md. The docs follow the baumit-docs
  # package through a Forgejo webhook (same runbook).
  MODULES.services.mdbook = {
    enable = true;
    # Only the Owners team of the baumit org on git.robo4you.at.
    allowedGroups = ["baumit:owners"];
  };
  # Client ID and secret come from sops (idp/client_id, idp/client_secret).
  MODULES.security.idp.enable = true;

  MODULES.services.sftpgo.enable = true;
  MODULES.services.i2pd.enable = false;
  MODULES.services.immich.machineLearning.enable = true;
  # MODULES.services.transmission.enable = true;
  MODULES.services.searx.enable = true;
  MODULES.nix.substituters.airlab-attic.enable = true;
  MODULES.nix.substituters.airlab-attic.push.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  services.logind.settings.Login = {
    # lid closed = keep working, on battery AND external power AND docked
    # (HandleLidSwitch alone only covers the battery case; the other two keys
    # default to "lock" in systemd >= 256 and win when AC/dock is active)
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
  };

  # services.cron = {
  #   enable = true;
  #   systemCronJobs = [
  #     "0 5 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g performance"
  #     "0 5 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=20000 --fast-limit=30000 --slow-limit=15000 --tctl-temp=90"

  #     "30 20 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g powersave -d 100 -u 100"
  #     "30 20 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=500 --fast-limit=1000 --slow-limit=100 --tctl-temp=30"
  #   ];
  # };

  networking = {
    networkmanager.enable = lib.mkForce true;
  };
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
  };
}
