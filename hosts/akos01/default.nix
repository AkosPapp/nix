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

    netbird_up=0
    if ip link show dev wt0 up >/dev/null 2>&1; then
      route=$(ip route get "$netbird_dns" 2>/dev/null) || route=
      case " $route " in
        *" dev wt0 "*)
          if [ -n "$(dig +time=1 +tries=3 +short "@$netbird_dns" "$netbird_zone" SOA 2>/dev/null)" ]; then
            netbird_up=1
          fi
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
in {
  config = {
    PROFILES.qemu-vm.enable = true;
    MODULES.nix.builders.airlab = true;
    MODULES.security.sops.enable = true;
    MODULES.networking.tailscale.hostIP = "100.83.255.5";
    MODULES.services.syncthing.deviceID = "ZNMNOF4-NH6MXMO-VCFTEPL-4CUQ2DC-Y7VR6WI-NHFOUKS-OK2GXAR-A7SVWQ2";
    MODULES.networking.traefik.enable = true;
    MODULES.services.vaultwarden.enable = true;
    MODULES.services.grafana.enable = true;
    MODULES.services.homepage.enable = true;
    MODULES.services.prometheus.enable = true;
    MODULES.services.loki.enable = true;
    MODULES.services.fastdds.enable = true;
    MODULES.services.mosquitto.enable = true;
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
