# VPN-aware split DNS: make dnsmasq the system resolver and regenerate its dynamic include
# whenever a VPN's usability actually changes. Every fleet host that runs Tailscale beside a
# public resolver needs exactly this; what a host decides per-machine is only the enable flag,
# whether it advertises the exit node / accepts tailnet routes, and how the AirLab forward is
# reached (static on the always-in-lab servers, interface-gated on the laptop).
#
# The resolver picture this sets up (the same one hp, legion5 and akos01 each hand-rolled
# before it lived here):
# - public backups, in strict order: the configured publicServers
# - AirLab's DNS only for its zone (the DHCP-provided servers are otherwise ignored)
# - Tailscale's MagicDNS and the other hosts' Traefik zones only while tailscale is connected
# - robo4you.at via netbird's r4uai01 (100.124.160.88) only while wt0 is up, the route to it
#   leaves through wt0, and it answers the zone. netbird's DNS client is disabled in
#   users/akos.nix.
# dnsmasq is restarted only when the generated include actually changes.
{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkForce mkIf mkOption types;

  cfg = config.MODULES.networking.dns.splitDns;

  # Other hosts' Traefik zones (by default their host name: hp, legion5, akos01, ...) and the
  # Tailscale IP behind each. Generated from the flake, so a new host needs no edit anywhere.
  tailnetZones = lib.filter (z: z.ip != null) (lib.mapAttrsToList (host: h: {
    domain = h.config.MODULES.networking.traefik.domain;
    ip = h.config.MODULES.networking.tailscale.hostIP;
  }) (lib.removeAttrs nixosConfigurations [configName]));

  tailnetDnsName = config.MODULES.networking.tailscale.tailnetDnsName;
  # `networking.domain` (modules/networking/tailscale.nix) = this host's tailnet FQDN, so glibc
  # qualifies every bare name as <name>.<selfFqdn> before trying the name itself.
  selfFqdn = "${configName}.${tailnetDnsName}";
  selfIP = config.MODULES.networking.tailscale.hostIP;

  # dnsmasq's dynamic include, regenerated on a timer. While tailscale is connected, every other
  # host's zone and tailnet FQDN resolve to that host's tailscale IP - including the search-
  # qualified form glibc tries first - and MagicDNS is only a fallback for unknown peers. The
  # labForward block is emitted per its options (see splitDns.script placement below).
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
        # Only a fallback now: forwards into MagicDNS crawl (or stall outright, see below), so
        # every name that matters is answered by the address= lines instead. This keeps tailnet
        # peers the flake doesn't know about resolvable, just slowly.
        echo "server=/${tailnetDnsName}/100.100.100.100"
        ${lib.concatMapStringsSep "\n    " (z: ''
        echo 'address=/${z.domain}/${z.ip}'
        echo 'address=/${z.domain}.${tailnetDnsName}/${z.ip}'
        echo 'address=/${z.domain}.${selfFqdn}/${z.ip}'
      '')
      tailnetZones}
        # glibc qualifies bare names with `networking.domain` (this host's tailnet FQDN), dnsmasq
        # forwards those to MagicDNS, MagicDNS answers authoritatively SERVFAIL for a sub-name of
        # a peer - and dnsmasq then never answers its client at all (measured on legion5
        # 2026-10-26: the same query <30ms direct, forever via dnsmasq; even the NOERROR replies
        # arrive ~3s late). Every plain-name lookup on the box stalled ~10s behind that first
        # search domain. The qualified forms of known hosts are answered locally instead, and the
        # own subtree becomes authoritative here: an unknown qualified name gets a fast NXDOMAIN
        # so glibc proceeds to the bare name, never through the swallowed forward.
        echo "host-record=${selfFqdn},${selfIP}"
        echo "local=/${selfFqdn}/"
      fi
      ${lib.optionalString (cfg.labForward.enable && cfg.labForward.interface != null) ''
      # The lab's server only answers on the lab LAN. Forwarding the zone while away is a
      # silent black hole - and the lab hands out its zone as search domain, so that black
      # hole sits in front of every bare name (and the lab has a machine of its own named
      # `hp`, which would shadow the tailnet zone outright). The line exists only while
      # ${cfg.labForward.interface} holds a lab address.
      case $(ip -4 -o addr show dev ${cfg.labForward.interface} 2>/dev/null) in
        *"inet ${cfg.labForward.addressPrefix}"*) echo "server=/${cfg.labForward.zone}/${cfg.labForward.server}" ;;
      esac
    ''}
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
in {
  options.MODULES.networking.dns.splitDns = {
    enable = mkEnableOption ''
      VPN-aware split DNS: dnsmasq as the system resolver with a dynamically regenerated
      include (tailnet zones while tailscale runs, the netbird zone while wt0 really works,
      public servers as the fallback), replacing systemd-resolved and tailscaled's own DNS
      management
    '';

    publicServers = mkOption {
      type = types.listOf types.str;
      default = [
        "9.9.9.9"
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "Upstream public resolvers, queried in this order (strict-order is set).";
    };

    acceptRoutes = mkOption {
      type = types.bool;
      default = true;
      description = "tailscale --accept-routes: install the tailnet routes this node is offered.";
    };

    advertiseExitNode = mkOption {
      type = types.bool;
      default = false;
      description = "tailscale --advertise-exit-node (also sets useRoutingFeatures = both).";
    };

    labForward = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Forward the lab zone to the lab's DNS server. With interface = null the forward is
          a static dnsmasq server= line (right for a box that physically sits in the lab);
          with an interface set it lives in the dynamic include instead and only exists while
          that interface holds an address from addressPrefix (right for a laptop that roams).
        '';
      };

      zone = mkOption {
        type = types.str;
        default = "airlab";
        description = "Lab DNS zone to forward.";
      };

      server = mkOption {
        type = types.str;
        default = "10.50.20.2";
        description = "Lab DNS server.";
      };

      interface = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "wlo1";
        description = "Emit the forward only while this interface holds a lab address; null = always.";
      };

      addressPrefix = mkOption {
        type = types.str;
        default = "10.50.";
        description = "IPv4 prefix that marks a lab address on `interface`.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = selfIP != null;
        message = "MODULES.networking.dns.splitDns needs MODULES.networking.tailscale.hostIP to be set.";
      }
      {
        assertion = cfg.labForward.interface == null || cfg.labForward.enable;
        message = "MODULES.networking.dns.splitDns.labForward.interface is set but labForward.enable is false.";
      }
    ];

    # dnsmasq owns the system resolver instead.
    services.resolved.enable = false;

    services.dnsmasq = {
      enable = true;
      # modules/networking/dns.nix already runs this host's authoritative zone in dnsmasq and
      # deliberately keeps it off the system resolver; here we also want it to be the system
      # resolver, and to keep listening on the tailscale address for the authoritative zone.
      resolveLocalQueries = mkForce true;
      settings = {
        # Never adopt the DHCP servers as defaults: the public list below is the fallback.
        no-resolv = mkForce true;
        # `no-resolv` already ignores this; drop the module's marker to avoid a startup warning.
        resolv-file = mkForce [];
        # The tailscale address may not exist yet when dnsmasq starts.
        bind-dynamic = mkForce true;
        listen-address = mkForce [
          "127.0.0.1"
          "::1"
          selfIP
        ];
        strict-order = true;
        server =
          cfg.publicServers
          ++ lib.optionals (cfg.labForward.enable && cfg.labForward.interface == null) [
            "/${cfg.labForward.zone}/${cfg.labForward.server}"
          ];
        # The dynamically generated include from the split-dns service below.
        conf-dir = "/run/dnsmasq.d,*.conf";
      };
    };

    # Tailscale still provides the tailnet; dnsmasq forwards its zone explicitly, so tailscaled
    # must not manage resolv.conf.
    services.tailscale =
      {
        extraSetFlags = mkForce [
          "--accept-dns=false"
          "--accept-routes=${lib.boolToString cfg.acceptRoutes}"
          "--advertise-exit-node=${lib.boolToString cfg.advertiseExitNode}"
        ];
      }
      // lib.optionalAttrs cfg.advertiseExitNode {
        useRoutingFeatures = "both";
      };

    systemd.tmpfiles.rules = [
      # dnsmasq's dynamic include directory, written by the split-dns service below.
      "d /run/dnsmasq.d 0755 root root -"
    ];

    systemd.services = {
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

    systemd.timers.split-dns = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5s";
        OnUnitActiveSec = "10s";
      };
    };
  };
}
