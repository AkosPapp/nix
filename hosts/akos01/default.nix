{
  pkgs,
  config,
  lib,
  ...
}: {
  config = {
    PROFILES.qemu-vm.enable = true;
    # 2026-11-11 user request: hardened kernel on the ZFS servers. nixpkgs 26.05 removed
    # linuxPackages_hardened ("lack of maintenance"), so modules/system/hardened-kernel.nix
    # rebuilds the pinned 6.18.59 with the grafix linux-hardened patchset (v6.18.59-hardened1)
    # + the vendored hardened defconfig, keeping the eBPF/kprobe floor coroot/docker/tailscale
    # need. Takes effect on the NEXT boot; the current generation stays selectable.
    # 2026-11-12: owner chose hardened 6.18.60 with independently updated
    # flake dependencies. Source and patch are pinned together by the module.
    MODULES.system.hardenedKernel.enable = true;
    MODULES.nix.builders.airlab = true;
    MODULES.security.sops.enable = true;
    # No X11 / ssh-agent auth on a server (2026-10-24 audit #8).
    MODULES.networking.sshd.x11Forwarding = false;
    MODULES.networking.sshd.agentAuth = false;
    MODULES.networking.tailscale.hostIP = "100.83.255.5";
    # Public SSH host keys keyed by tailnet IP - pinned by every fleet hub catalog
    # (modules/services/herdr.nix) and readable by humans as `ssh herdr-akos01`. Cross-checked
    # 2026-11-10: keyscan over tailscale0 == the `100.83.255.5` entries in hp's
    # /root/.ssh/known_hosts, verified identity not TOFU. The rsa line's comment still says
    # root@akos01zfs because the key predates this host's rename to akos01 (the zfs-root
    # VM's original name).
    MODULES.networking.sshClient.hostKeys = [
      "100.83.255.5 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHHqlpfnUw96jh5f6doxd+ThejCSC6EwEnxrAPPttMup"
      "100.83.255.5 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCexStvKObMSDoxaU3FnygbC/ITflGJChHeHn+6Gpf6RPk01Hf69gs0YWitbutv6G+TNgRheQHjOodpnSHPUQqXdFczoqSC3Ou0LPWUitUHn+aKKkpzzl5iuEaHawH5auZzbYLLMKEopmkEbKn5Haju36u2/3mSc+TXMtOZ+VEZ9ubSxLlfhRQIErJncdmQHJXjphpT8MqxRf6PP6BRB7YSo+vRH/VG0ObN5hnhHzKPirRP3SFkRYjq95JHPuoDtpMdnkuw46pzwwsJMZYgNgMxRyP+P35jK8DzXQ99tpI5AATzY6Zi+bCPv8yN7fERkRRZE00O+V5txVO6df0Gu/MDFoyIpru/RWVnr43hQAQT3H+6NE/7l3KWf1QEe5qi83Mz4AadaFB4cj+aojD0kO6InufnUpiXc2+4dfzTJAH4/o46gMHV29boLQXPlCA3X3HD5wXLm1GYZcqZ3iY1lL2+kYtPSlC+/88whPr5S0kDon8oUhn5bFIX7NJMNgn5vqndpDG1t4iHKXvo0AhbLWMzRc2Mm38pD6fSqqRcpj0hBccJrUe5pqpMt2hiweb56QsVGoED3B7kTn+JjsWnkpb6s1agKGITNQi/DThqCWC2Xy4lE191/Jpvs0IhBxqnshYyzDoJPcfX3ftsHy4fncyQFYgys+qaOA9vC2FnDUNNIw== root@akos01zfs"
    ];
    # Nightly: pull the fastdds discovery-server image (docker-images-update.nix).
    MODULES.virtualisation.docker-images-update.enable = true;
    # herdr (herdr.dev): binaries only, same reasoning as hp - no normal user account here
    # (no USERS.akos), so no GUI. hc on PATH is what lets this box be an `hc machine add
    # akos01` target; installApp = false keeps vulkan/mesa out of a VM with no display
    # server. See modules/services/herdr.nix for why the servers themselves stay unmanaged
    # (herdr-core spawns its own transient systemd --user units; the TUI's server is
    # auto-started by the hub's incoming bridge - src/remote/host.rs ensure_remote_server_running).
    # users.root mirrors hp: the fleet hub (hp) dials this box as root from its declared
    # catalog, and the incoming herdr server needs the 0700 config/state scaffolding (saved
    # screens hold agent scrollback with API keys) plus linger for root's transient units.
    MODULES.services.herdr = {
      enable = true;
      installApp = false;
      users.root = {
        enable = true;
        cli.enable = true;
      };
    };
    # Same phone public key as the hub/laptop; private key stays on the phone.
    users.users.root.openssh.authorizedKeys.keys = [
      (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-mobile.pub))
    ];
    MODULES.services.syncthing.deviceID = "ZNMNOF4-NH6MXMO-VCFTEPL-4CUQ2DC-Y7VR6WI-NHFOUKS-OK2GXAR-A7SVWQ2";
    MODULES.networking.traefik.enable = true;
    MODULES.services.vaultwarden.enable = true;
    MODULES.services.grafana.enable = true;
    MODULES.services.homepage.enable = true;
    MODULES.services.prometheus.enable = true;
    MODULES.services.loki.enable = true;
    # Coroot server - THE fleet aggregation point since 2026-10-26: hp's own server half was
    # disabled and hp (plus the vm-agents guest) now push here as agents; this server
    # visualises the whole fleet. UI publishes through Traefik on this host
    # (coroot.<this host's domain>); the local eBPF agent pushes to it over loopback.
    # The multi-server mode itself remains supported (see modules/services/coroot.nix).
    MODULES.services.coroot.enable = true;
    # 2026-11-14 (owner ask): EE binary + sops license (coroot/license_key) + Coroot Cloud
    # org key (coroot/cloud_api_key) - enables AI RCA and the enterprise features; the
    # community agent package stays version-paired on the same minor (see the module).
    MODULES.services.coroot.enterprise = true;
    # Coroot RCA -> Postgres metrics for this box's cluster (immich's DB; the agent here
    # collects it). Role/extensions provisioned by postgresql.nix - note the unit is NOT
    # jailed, it talks to the jailed server through the shared /run/postgresql socket.
    MODULES.services.postgres.corootIntegration.enable = true;
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
    # PLAN §7: graph in ENFORCE on this host - the 2026-11-13 audit flipped it deliberately
    # and this comment is its ledger (audit finding #12: the stale "observe mode, flip
    # after a week of sg-seen" gate prose is what was wrong, not the toggle). 2026-10-25:
    # Suricata IDS tap ALSO enabled on this host on request - previously hp-only ("one tap
    # is enough", the tailnet aggregation point; this second tap now covers the
    # grafana/loki/prometheus/vaultwarden half of the fleet directly). allow = [] holds
    # host-local additions only: cross-host edges live in the fleet table
    # (modules/security/service-graph.nix), and undeclared TCP still gets the rate-limited
    # sg-seen log BEFORE the reject, so drift stays observable the same way.
    MODULES.security.serviceGraph = {
      # 2026-11-12: independent nftables hook survives VPN rule reordering.
      enforce = true;
      enable = true;
      suricata.enable = true;
      allow = [];
    };
    # 2026-11-12: akos01 has no public door (no cloudflare services, no funnel), so
    # MODULES.networking.traefik.accessLogs stays off here - traefik.nix asserts it,
    # and there is no public traffic to analyze. What akos01 DOES do is mirror its
    # FLEET streams (suricata EVE from this host's tap) to hp's Loki - hp is the
    # aggregator (acceptFleetPush) - while the journal spine keeps going to the
    # local Loki. Grafana here queries the same fleet Loki via fleetQueryUrl, so
    # both boxes' IDS dashboards show the whole tailnet picture either way.
    MODULES.services.loki = {
      fleetPushTargets = ["http://100.92.36.52:${toString config.PORTS.loki}/loki/api/v1/push"];
      fleetQueryUrl = "http://100.92.36.52:${toString config.PORTS.loki}";
    };
    MODULES.security.audit.enable = true;
    MODULES.security.audit.execUsers = ["postgres"];
    # PLAN §4: L1 on this box; the hp replica (L2) arrives pushed - no local schedule
    # needed for zroot/persist/hp, znapzend prunes received snapshots at the source.
    MODULES.system.znapzend = {
      enable = true;
      # no dataset of its own - the dir lives on zroot/root and is covered by L1
      pgDumpDir = "/var/lib/pgdump";
      # One-way replication trust, scoped: hp's key (sops znapzend/ssh_key_b64, decoded to
      # /etc/ssh/znapzend/id_ed25519 on hp) may only run replica-shaped `zfs` verbs under
      # zroot/persist/hp here - no shell, no pty, no forwarding, nothing outside the replica
      # (forced-command shell and the authorizedKeys wiring live in
      # modules/system/znapzend.nix).
      acceptPush = {
        enable = true;
        datasetPrefix = "zroot/persist/hp";
        authorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGc2CcdIPHVHIjd9anoANccvB9kL56guCP+vPCfBpboG znapzend-hp-to-akos01";
      };
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
      # OFF (2026-10-26): its build loop races manual `deploy --remote-build` runs on this
      # host (contending store/daemon), which aborted an akos01 deploy mid-flight. Flip back
      # on when autobuilding this repo from akos01 is wanted again.
      enable = false;
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

    # VPN-aware split DNS (modules/networking/dns/split-dns.nix): dnsmasq as the system
    # resolver, tailnet zones only while tailscale runs, robo4you.at only while netbird really
    # works, public servers as the fallback (this replaces the previous unconditional
    # /robo4you.at/10.50.20.2 forwarding; netbird's DNS client is disabled in users/akos.nix).
    # The box sits in the lab permanently, so the /airlab forward is static; it advertises the
    # tailnet exit node but accepts no offered routes (its default route is the lab LAN).
    MODULES.networking.dns.splitDns = {
      enable = true;
      acceptRoutes = false;
      advertiseExitNode = true;
      labForward.enable = true;
    };

    environment.systemPackages = with pkgs; [
      wget
      curl
      git
      htop
      tmux
      dnsutils
    ];

    nix.settings = {
      download-buffer-size = 524288000; # 500 MiB
    };

    networking.hostId = "68bf4e0e";
    boot.loader.grub.enable = true;
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.forceImportRoot = false;
    boot.zfs.devNodes = "/dev";
    boot.loader.grub.zfsSupport = true;
    # ARC policy (2026-11-11, owner call): NO zfs_arc_max cap here. This box's files
    # live on a slow CIFS-mounted Ceph drive, so ARC is the difference between 0.1ms
    # and multi-second reads, and 100%-of-free-RAM is fine. What the 2026-11-11 stall
    # incident (node-exporter >20s hung scrapes at 83% PSI, immich-api/microservices
    # scrape timeouts, coroot "memory pressure" x3) actually needed was faster ARC
    # yield, not a smaller ARC: modules/system/zfs-tuning.nix (auto-on for any host
    # with zfs in supportedFilesystems) lifts the reclaim wake-up watermarks so
    # kswapd shrinks the ARC before cgroups start stalling, and keeps a standing
    # 1 GiB free-RAM floor the ARC never grows into (arcHeadroom). Measured live:
    # exporters answer in 0.04-0.28s, PSI 0.0, zero direct-reclaim stalls while the
    # ARC refills under kswapd's supervision.

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
