{
  pkgs,
  lib,
  config,
  nixosConfigurations,
  configName,
  ...
}: let
  # Other hosts' Traefik zones (by default their host name: hp, legion5, ...) and the Tailscale IP
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
  # PLAN §4: the forced command hp's znapzend ssh key is locked to. sshd confines this
  # key to `zfs` sub-commands and nothing else (no shell, no pty, no forwarding) - but
  # the old form accepted ANY zfs arguments, i.e. `zfs destroy -r zroot/<anything>` and
  # `zfs recv -F` outside the replica were in the stolen-hp blast radius. Now: only the
  # subcommand set znapzend's ssh protocol uses, and every dataset-shaped argument
  # (containing / or @) must live under the replica dataset - L2's real blast radius.
  # znapzend prunes received snapshots from the SOURCE, so `destroy`/`-F` here stay
  # within the same prefix (autoCreation + rollback cleanup); no other host needs it.
  # NOTE on the input path: with a forced command, sshd's do_exec() REPLACES the client
  # command line with the forced one and delivers the client's original command ONLY in
  # $SSH_ORIGINAL_COMMAND (session.c) - reading $@ would reject every legitimate
  # invocation. Parse that env var; argv stays supported so root can exercise the
  # filters locally (`znapzend-shell zfs list ...`).
  znapzendShell = pkgs.writeShellScriptBin "znapzend-shell" ''
    ds_prefix="zroot/persist/hp"
    die() { echo "znapzend-shell: disallowed: $*" >&2; exit 1; }

    if [ "$#" -eq 0 ]; then
      cmd=''${SSH_ORIGINAL_COMMAND:-}
      [ -n "$cmd" ] || die "no command"
      # Honor the single quotes znapzend wraps around tokens containing characters
      # outside [-/@=_0-9a-z] (snapshot timestamps carry ':') by letting bash
      # re-parse the line - but only after pinning the WHOLE line to that charset:
      # no ; | & $ " backslash ( ) < > { } [ ] * ? ! ~ # % ^ ,tab ,newline survive the
      # gate, so the eval can do nothing but word-split and remove quotes. `=` is IN
      # the charset so the whitelisted `set` verb's property=value operands can reach
      # eval at all (2026-10-25 review nit); a bare `a=b` token after `set --` is
      # inert - it is a positional arg, never an assignment. An
      # unbalanced quote then just fails to parse and $1 stays empty -> die below.
      # The class lives in a variable because a bare ' inside a case-pattern
      # bracket (or a //pattern/ expansion) would open a quote in bash's lexer.
      bad_re="[^-A-Za-z0-9_=/.:,'@ ]"
      if [[ "$cmd" =~ $bad_re ]]; then die "charset"; fi
      eval set -- $cmd
    fi
    if [ "$1" = "zfs" ]; then shift; fi
    case "$1" in
      version)
        [ "$#" -eq 1 ] || die "$*"
        exec ${pkgs.zfs}/sbin/zfs version ;;
      recv|create|destroy|list|get|set|mount|umount) ;;
      *)
        die "$*" ;;
    esac
    # Operand scoping. A bare pool name (zroot, rpool) contains no "/" so a slash test
    # alone would let `zfs destroy zroot` through - pool-level operands must be pinned
    # positively, per verb:
    #   recv/create/mount/umount: every non-option operand IS a dataset
    #     (znapzend remote ops never pass -o key=value through these) -> must be under
    #     the prefix; `zfs set a=b <ds>`'s property argument would also fail this, which
    #     is correct here (set belongs to the next rule).
    #   destroy: same, modulo the comma grammar documented at destroy_operand.
    #   set: operands are `property=value` pairs plus datasets - pairs pass, everything
    #     else must be under the prefix (blocks `zfs set x=y zroot`).
    #   list/get: read-only; slash-bearing operands (datasets/snapshots) still pinned,
    #     bare names only ever leak inventory.
    # And per COMMA ELEMENT, not per token: znapzend's combinedDestroy (ZFS.pm) prunes
    # every expired snapshot as ONE comma-joined argument in ZFS grammar
    # `fs@snapA,snapB` - only the FIRST element carries the dataset, and ZFS parses a
    # later element as a snapshot OF THAT SAME dataset, never as another target. So
    # destroy_operand pins the first element under the replica prefix and accepts bare
    # continuation names; `zroot/persist/hp@a,zroot/root@b` still dies on the second
    # element's "/". (The old every-element rule rejected znapzend's own legitimate
    # multi-snapshot prune - 2026-10-25 review #2, destination snapshots piled up.)
    under_prefix() {
      case "$1" in
        "$ds_prefix"|"$ds_prefix"/*|"$ds_prefix"@*) return 0 ;;
        *) return 1 ;;
      esac
    }
    # check $2 against every comma element of $1 (empty elements die: `a,` / `,a` /
    # `a,,b` are exactly where a foreign name hides).
    every_element() {
      local elem IFS=,
      case "$1" in ,*|*,|*,,*) return 1 ;; esac
      for elem in $1; do "$2" "$elem" || return 1; done
      return 0
    }
    pinned_operand() { under_prefix "$1"; }
    # zfs-destroy comma grammar (see above): first element fully pinned, continuation
    # elements snapshot names of the SAME dataset - any / or @ in them means someone
    # is trying to point the destroy elsewhere.
    destroy_operand() {
      local first=1 elem IFS=,
      case "$1" in ,*|*,|*,,*) return 1 ;; esac
      for elem in $1; do
        if [ "$first" = 1 ]; then
          under_prefix "$elem" || return 1
          first=0
        else
          case "$elem" in */*|*@*) return 1 ;; esac
        fi
      done
      return 0
    }
    # list/get only pin elements that look like datasets (contain / or @); the -t
    # type list ("filesystem,volume") and property names pass untouched.
    read_operand() {
      case "$1" in
        */*|*@*) under_prefix "$1" ;;
        *) true ;;
      esac
    }
    sub="$1"
    for a in ''${@:2}; do
      case "$a" in -*) continue ;; esac
      case "$sub" in
        destroy)
          destroy_operand "$a" || die "$*" ;;
        recv|create|mount|umount)
          every_element "$a" pinned_operand || die "$*" ;;
        set)
          case "$a" in
            *=*) ;;
            *) every_element "$a" pinned_operand || die "$*" ;;
          esac ;;
        list|get)
          every_element "$a" read_operand || die "$*" ;;
      esac
    done
    exec ${pkgs.zfs}/sbin/zfs "$@"
  '';
in {
  config = {
    PROFILES.qemu-vm.enable = true;
    MODULES.nix.builders.airlab = true;
    MODULES.security.sops.enable = true;
    # No X11 / ssh-agent auth on a server (2026-10-24 audit #8).
    MODULES.networking.sshd.x11Forwarding = false;
    MODULES.networking.sshd.agentAuth = false;
    MODULES.networking.tailscale.hostIP = "100.83.255.5";
    # Nightly: pull the fastdds discovery-server image (docker-images-update.nix).
    MODULES.virtualisation.docker-images-update.enable = true;
    MODULES.services.syncthing.deviceID = "ZNMNOF4-NH6MXMO-VCFTEPL-4CUQ2DC-Y7VR6WI-NHFOUKS-OK2GXAR-A7SVWQ2";
    MODULES.networking.traefik.enable = true;
    MODULES.services.vaultwarden.enable = true;
    MODULES.services.grafana.enable = true;
    MODULES.services.homepage.enable = true;
    MODULES.services.prometheus.enable = true;
    MODULES.services.loki.enable = true;
    # Coroot server on this host too (2026-10-25): each fleet host now has its OWN Coroot
    # server + web UI - this one visualises only akos01. Its UI publishes through Traefik
    # on this host (coroot.<this host's domain>); the local eBPF agent pushes to it over
    # loopback. Data stays local - this is NOT a replacement for hp's hub, which keeps
    # visualising hp (and any agentEnable-only host still points there).
    MODULES.services.coroot.enable = true;
    # PLAN §2 Tier A + §3.4 egress LOG (see modules/security/jail.nix; hp carries the full
    # data-tier set). postgresql here serves the Immich stack over the unix socket; the deny
    # chain only stops NEW outbound flows, replies ride conntrack.
    MODULES.security.jails.postgresql.enable = true;
    MODULES.security.jails.homepage.enable = true;
    MODULES.security.jails.searx.enable = true;
    MODULES.security.jails.prometheus.enable = true;
    MODULES.security.jails.loki.enable = true;
    MODULES.security.jails.grafana.enable = true;
    MODULES.security.jails.syncthing.enable = true;
    MODULES.security.jails.vaultwarden.enable = true;
    # PLAN §3 (see hp for the rationale; here only the Immich-stack DB user earns an execve
    # key - no code-running agents live on this box).
    # PLAN §7: graph in observe mode here too; `enforce` stays off until a week of
    # explainable sg-seen / suricata logs (same gate as hp). 2026-10-25: Suricata IDS tap
    # ALSO enabled on this host on request - previously hp-only ("one tap is enough", the
    # tailnet aggregation point; this second tap now covers the grafana/loki/prometheus/
    # vaultwarden half of the fleet directly). allow = [] = observe mode: every undeclared
    # tailnet edge is logged, edges become explicit as sg-seen logs make the case.
    MODULES.security.serviceGraph = {
      enable = true;
      suricata.enable = true;
      allow = [];
    };
    MODULES.security.audit.enable = true;
    # One-way replication trust, scoped (see znapzendShell above; hp's keypair lives in
    # sops znapzend/ssh_key_b64, decoded to /etc/ssh/znapzend/id_ed25519 by its module).
    users.users.root.openssh.authorizedKeys.keys = [
      ("command=\"${znapzendShell}/bin/znapzend-shell\","
        + "no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding "
        + "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGc2CcdIPHVHIjd9anoANccvB9kL56guCP+vPCfBpboG znapzend-hp-to-akos01")
    ];
    MODULES.security.audit.execUsers = ["postgres"];
    # PLAN §4: L1 on this box; the hp replica (L2) arrives pushed - no local schedule
    # needed for zroot/persist/hp, znapzend prunes received snapshots at the source.
    MODULES.system.znapzend = {
      enable = true;
      # no dataset of its own - the dir lives on zroot/root and is covered by L1
      pgDumpDir = "/var/lib/pgdump";
      jobs = [
        {
          dataset = "zroot/root";
          plan = "1d=>1h,2w=>1d,8w=>1w";
        }
      ];
    };

    MODULES.services.fastdds.enable = true;
    # Off per the 2026-10-24 security audit (#2): the broker was anonymous with a
    # readwrite-on-everything ACL, open on every interface. If MQTT comes back, it goes
    # behind a password file (sops) and a tailscale-scoped firewall before akos01 reboots.
    MODULES.services.mosquitto.enable = false;
    MODULES.services.searx.enable = true;
    MODULES.services.immich.enable = true;
    MODULES.nix.substituters.airlab-attic.enable = true;
    MODULES.nix.substituters.airlab-attic.push.enable = true;

    sops.secrets."git.robo4you.at/akos01-nix-autobuild" = {
      mode = "0400";
    };

    services.nix_autobuild = {
      enable = true;
      settings = {
        repos = [
          {
            url = "github.com/AkosPapp/nix";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 2;
          }
          {
            url = "github.com/AkosPapp/nixvim";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 2;
          }
          {
            url = "github.com/AkosPapp/nix_autobuild";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 2;
          }
          {
            url = "git.robo4you.at/akos.papp/DA2";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 2;
          }
          {
            url = "git.robo4you.at/flyby/blender-sdg";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 2;
            credentials_file = config.sops.secrets."git.robo4you.at/akos01-nix-autobuild".path;
          }
        ];
        n_build_threads = 2;
        builders = ["ssh-ng://builder@r4unb02.airlab"];
        dir = "/tmp/nix_autobuild";
        supported_architectures = ["x86_64-linux"];
        host = "127.0.0.1";
        port = config.PORTS.nixAutobuild;
        copy_to = ["ssh-ng://builder@r4unb02.airlab" "ssh-ng://root@hp"];
      };
    };
    MODULES.networking.traefik.services.nix = "127.0.0.1:${toString config.PORTS.nixAutobuild}";

    networking = {
      useDHCP = true;
    };

    # One local resolver (dnsmasq) instead of systemd-resolved, because the split depends on
    # whether each VPN is actually usable:
    # - public backups, in the requested order: 9.9.9.9, 1.1.1.1, 8.8.8.8
    # - AirLab's DNS only for its zone (the DHCP-provided servers are otherwise ignored)
    # - Tailscale's MagicDNS and the other hosts' Traefik zones only while tailscale is connected
    # - robo4you.at via netbird's r4uai01 (100.124.160.88) only while wt0 is up, the route to it
    #   leaves through wt0, and it answers the zone. netbird's DNS client is disabled in
    #   users/akos.nix.
    # This replaces the previous unconditional /robo4you.at/10.50.20.2 forwarding. The dynamic
    # parts come from splitDns above; dnsmasq is restarted only when its include changes.
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

    systemd.tmpfiles.rules = ["d /run/dnsmasq.d 0755 root root -"];

    systemd.services.split-dns = {
      description = "Regenerate dnsmasq's VPN-dependent split-DNS include";
      # A transient dnsmasq restart failure must not stop the timer from retrying.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${splitDns}";
      };
    };
    systemd.timers.split-dns = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5s";
        OnUnitActiveSec = "10s";
      };
    };

    systemd.services.split-dns-watch = {
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

    environment.systemPackages = with pkgs; [
      wget
      curl
      git
      htop
      tmux
      dnsutils
    ];

    services.tailscale = {
      extraSetFlags = lib.mkForce [
        # dnsmasq owns the system resolver and forwards the tailnet zone explicitly.
        "--accept-dns=false"
        "--accept-routes=false"
        "--advertise-exit-node=true"
      ];
      useRoutingFeatures = "both";
    };

    nix.settings = {
      download-buffer-size = 524288000; # 500 MiB
    };

    networking.hostId = "68bf4e0e";
    boot.loader.grub.enable = true;
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.forceImportRoot = false;
    boot.zfs.devNodes = "/dev";
    boot.loader.grub.zfsSupport = true;

    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
      neededForBoot = true;
    };
    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
      neededForBoot = true;
    };

    swapDevices = [
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDA";}
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDB";}
    ];

    disko.devices.disk = {
      VDA = {
        device = "/dev/vda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            boot-ext4 = {
              size = "1G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot";
                mountOptions = ["defaults"];
              };
            };
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDA"]; # unique label for the swap partition on vda
              };
            };
          };
        };
      };
      VDB = {
        device = "/dev/vdb";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDB"]; # unique label for the swap partition on vdb
              };
            };
          };
        };
      };
    };

    disko.devices.zpool = {
      zroot = {
        type = "zpool";
        mountpoint = null;
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options.canmount = "noauto";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.canmount = "noauto";
          };
          # immich-pictures = {
          #   type = "zfs_fs";
          #   mountpoint = "/var/lib/immich";
          #   options.compression = "lz4";
          # };
        };
      };
    };
  };
}
