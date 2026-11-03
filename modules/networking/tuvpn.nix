# TU Wien VPN, three cooperating halves (designed 2026-11-03):
#
#   client   (cfg.enable)              - the interactive wofi helper + sudo rules. Lives on the
#                                        desktop (legion5) and stays the fastest path while
#                                        physically on/near campus.
#   server   (server.enable)           - openconnect as a root systemd unit + the transit
#                                        plumbing, on a box LAN-adjacent to the TU gateway.
#                                        hp is that box: it physically sits in the AirLab, so
#                                        its leg to vpn.tuwien.ac.at is sub-millisecond and
#                                        loss-free, which is exactly what kills the TCP-in-TCP
#                                        collapse that makes a far-away laptop's own
#                                        openconnect --no-dtls session crawl.
#   viaHost  (client side)             - `tuvpn-via-<host>` toggle: starts the server unit on
#                                        the tunnel host over tailnet SSH, then flips
#                                        --accept-routes so the TU prefixes hp advertises as
#                                        Tailscale subnet routes get installed locally.
#
# The transit chain on the server host: legion5's TU-bound packets arrive on tailscale0, are
# FORWARDed into the openconnect tunnel (tun0) and MASQUERADEd, so they leave as this box's
# (account's) VPN address. hp's OWN traffic never enters the tunnel: profile 1_TU_getunnelt is
# split (no default route), and only the TU prefixes are advertised to the tailnet.
#
# Lifecycle is deliberately ON-DEMAND (the toggle drives the service; server.startAtBoot=false
# by default): the tunnel exists only while someone is using it, so the account's fixed VPN
# address is not held 24/7. That makes two ordering rules load-bearing, and the toggle
# implements both: start hp's unit BEFORE accepting routes (never advertise dead routes ->
# blackhole), and drop routes BEFORE stopping it. The unit's ExecStartPost gates `systemctl
# start`'s return on "tunnel up AND routes advertised", and ExecStopPost always retracts the
# advertisement, so the script can stay sequential.
{
  config,
  pkgs,
  lib,
  nixosConfigurations ? {},
  configName ? "",
  ...
}: let
  cfg = config.MODULES.networking.tuvpn;

  # The tailscale binary the node actually runs (pkgs-unstable via modules/networking/
  # tailscale.nix on the enabled hosts). Both the sudo rules and the scripts must name THIS
  # path - a NOPASSWD rule pinned to the stable package would silently never match.
  tsBin = config.services.tailscale.package;

  # ------------------------------------------------------------------ client --------------
  tuvpn-connect = pkgs.writeShellScriptBin "tuvpn-connect" ''
    set -euo pipefail

    VPN_HOST="vpn.tuwien.ac.at"

    PROFILE=$(printf "1_TU_getunnelt\n2_Alles_getunnelt\n3_TU_ohne_fixe_Adresse\nDisconnect\n" | \
      ${pkgs.wofi}/bin/wofi --dmenu --prompt="Select VPN profile" --lines=4)

    if [[ -z "$PROFILE" ]]; then
      echo "No profile selected, aborting." >&2
      exit 1
    fi

    sudo ${pkgs.psmisc}/bin/killall openconnect || true

    if [[ "$PROFILE" == "Disconnect" ]]; then
      echo "Disconnected from $VPN_HOST."
      exit 0
    fi

    USER=$(cat ${config.sops.secrets."tu/vpn/user".path})
    PASS=$(cat ${config.sops.secrets."tu/vpn/pass".path})
    TOTP_SECRET=$(cat ${config.sops.secrets."tu/vpn/totp".path})

    OTP=$(${pkgs.oath-toolkit}/bin/oathtool --totp -b "$TOTP_SECRET")

    echo "Connecting to $VPN_HOST with profile '$PROFILE'..."

    printf '%s\n%s\n' "$PASS" "$OTP" | \
      sudo ${pkgs.openconnect}/bin/openconnect \
        --protocol=anyconnect \
        --no-dtls \
        --no-external-auth \
        --authgroup="$PROFILE" \
        --user="$USER" \
        --passwd-on-stdin \
        "$VPN_HOST"
  '';

  tuvpn-connect-desktop = pkgs.makeDesktopItem {
    name = "tuvpn-connect";
    desktopName = "TU VPN";
    comment = "Connect to or disconnect from the TU Wien VPN";
    icon = "network-vpn";
    exec = "${tuvpn-connect}/bin/tuvpn-connect";
    terminal = false;
    categories = ["Network"];
  };

  # ------------------------------------------------------------- client via host ----------
  # The tailnet IP is baked in (cross-host facts flow through the flake's
  # nixosConfigurations specialArgs, Rule 2) so the toggle never depends on DNS
  # resolving - it is the tool you reach for precisely when connectivity is weird.
  viaTarget = lib.optionalAttrs (cfg.viaHost != null) (
    nixosConfigurations.${cfg.viaHost} or {}
  );
  viaIP = viaTarget.config.MODULES.networking.tailscale.hostIP or null;

  tuvpn-via = pkgs.writeShellScriptBin "tuvpn-via-${cfg.viaHost}" ''
    set -uo pipefail

    TS="${tsBin}/bin/tailscale"
    JQ="${pkgs.jq}/bin/jq"
    SSH="${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ConnectTimeout=6 root@${viaIP}"
    VIA="${cfg.viaHost}"

    # Accept-state proxy: SecondaryRoutes[].Enabled is false while --accept-routes is off,
    # so it doubles as the toggle's memory. (tailscale's own status --json carries no flat
    # accept-routes field worth grepping.) The tailscaled socket is root-only, so even the
    # read goes through the exact-command sudo rule.
    ENABLED=$(sudo $TS status --json 2>/dev/null | $JQ '[.SecondaryRoutes[]? | select(.Enabled)] | length')

    case "''${1:-status}" in
      on)
        # Order is load-bearing: hp starts first (its ExecStartPost returns only once the
        # tunnel is up and the routes are advertised), the laptop accepts second. Accepting
        # before the tunnel exists would blackhole TU-bound packets into a dead next-hop.
        if ! $SSH systemctl start tuvpn; then
          echo "could not start tuvpn on $VIA (needs tailnet ssh root@$VIA with a key)" >&2
          exit 1
        fi
        sudo $TS set --accept-routes=true
        echo "TU VPN via $VIA: ON - TU prefixes route through hp's tunnel now."
        ;;
      off)
        # Mirror order: stop accepting first, then tear the tunnel down.
        sudo $TS set --accept-routes=false
        $SSH systemctl stop tuvpn >/dev/null 2>&1 || true
        echo "TU VPN via $VIA: OFF"
        ;;
      toggle)
        if [ "''${ENABLED:-0}" -gt 0 ]; then
          exec $0 off
        else
          exec $0 on
        fi
        ;;
      restart)
        # Plain re-dial: fresh OTP, routes re-advertised; the laptop's accept-routes is
        # untouched, so the only blip is the reconnect itself.
        $SSH systemctl restart tuvpn
        echo "tuvpn on $VIA restarted (fresh dial, ~5s until the tunnel answers again)."
        ;;
      status)
        HP=$($SSH systemctl is-active tuvpn 2>/dev/null) || HP="''${HP:-ssh-unreachable}"
        echo "$VIA tuvpn.service: $HP"
        sudo $TS status --json 2>/dev/null | $JQ -r \
          '"tailnet routes: " + (if ([.SecondaryRoutes[]?] | length) > 0 then ([.SecondaryRoutes[] | .Route + (if .Enabled then " (enabled)" else " (not accepted)" end)] | join(", ")) else "none advertised" end)'
        ;;
      *)
        echo "usage: tuvpn-via-$VIA {on|off|toggle|restart|status}" >&2
        exit 2
        ;;
    esac
  '';

  # wofi front for the desktop entry - mirrors the tuvpn-connect UX (pick an action, no
  # terminal), result comes back as a notification because terminal=false has nowhere to
  # print to.
  tuvpn-via-menu = pkgs.writeShellScriptBin "tuvpn-via-${cfg.viaHost}-menu" ''
    set -uo pipefail

    CHOICE=$(printf "Connect via ${cfg.viaHost}\nDisconnect\nStatus\nRestart tunnel on ${cfg.viaHost}\n" | \
      ${pkgs.wofi}/bin/wofi --dmenu --prompt="TU VPN via ${cfg.viaHost}" --lines=4) || exit 1

    case "$CHOICE" in
      "Connect via ${cfg.viaHost}") ACTION=on ;;
      "Disconnect") ACTION=off ;;
      "Status") ACTION=status ;;
      "Restart tunnel on ${cfg.viaHost}") ACTION=restart ;;
      *) exit 1 ;;
    esac

    OUT=$(${tuvpn-via}/bin/tuvpn-via-${cfg.viaHost} "$ACTION" 2>&1)
    RC=$?
    ${pkgs.libnotify}/bin/notify-send -t 6000 "TU VPN via ${cfg.viaHost}" "$OUT" || true
    exit $RC
  '';

  tuvpn-via-desktop = pkgs.makeDesktopItem {
    name = "tuvpn-via-${cfg.viaHost}";
    desktopName = "TU VPN via ${cfg.viaHost}";
    comment = "Route the TU Wien VPN through ${cfg.viaHost}'s tunnel (tailscale subnet routes)";
    icon = "network-vpn";
    exec = "${tuvpn-via-menu}/bin/tuvpn-via-${cfg.viaHost}-menu";
    terminal = false;
    categories = ["Network"];
  };

  # ------------------------------------------------------------------ server --------------
  # vpnc-script wrapper: the tunnel must not adopt TU's DNS. The script rewrites the system
  # resolver only while INTERNAL_IP*_DNS is set (both ends of this design keep their own
  # split-DNS resolvers - hp's is dnsmasq via modules/networking/dns/split-dns.nix, and
  # TU-pushed servers would poison it the first time the tunnel came up); blank the inputs
  # and the modify/restore branches both no-op. The split-include ROUTES, which are the
  # whole point, are untouched.
  tuvpn-vpnc-script = pkgs.writeShellScript "tuvpn-vpnc-script" ''
    export INTERNAL_IP4_DNS= INTERNAL_IP6_DNS=
    exec ${pkgs.vpnc-scripts}/bin/vpnc-script "$@"
  '';

  # password + fresh TOTP as openconnect expects them on stdin (same two-line shape the
  # client pipes). Re-run on every start attempt, so a Restart=always re-dial never reuses
  # a burned 30s window.
  tuvpn-creds = pkgs.writeShellScript "tuvpn-creds" ''
    umask 077
    printf '%s\n%s\n' \
      "$(cat ${config.sops.secrets."tu/vpn/pass".path})" \
      "$(${pkgs.oath-toolkit}/bin/oathtool --totp -b "$(cat ${config.sops.secrets."tu/vpn/totp".path})")" \
      > /run/tuvpn/creds
  '';

  tuvpn-exec = pkgs.writeShellScript "tuvpn-exec" ''
    exec ${pkgs.openconnect}/bin/openconnect \
      --protocol=anyconnect \
      ${lib.optionalString cfg.server.noDtls "--no-dtls"} \
      --no-external-auth \
      --tun-device=${cfg.server.tunDevice} \
      --keepalive=30 \
      --script ${tuvpn-vpnc-script} \
      --authgroup=${lib.escapeShellArg cfg.server.profile} \
      --user="$(cat ${config.sops.secrets."tu/vpn/user".path})" \
      --passwd-on-stdin \
      ${lib.escapeShellArg cfg.server.gateway} < /run/tuvpn/creds
  '';

  routeCsv = lib.concatStringsSep "," cfg.server.tuPrefixes;

  # GATE for `systemctl start`: returns only once the tunnel carries routes AND the tailnet
  # has been told about them. The tailscale-up poll copies modules/networking/tailscale.nix
  # (tailscaled goes "active" long before it has a tailnet IP; `tailscale set` before that
  # just fails).
  tuvpn-advertise = pkgs.writeShellScript "tuvpn-advertise" ''
    export PATH="${lib.makeBinPath [tsBin pkgs.iproute2 pkgs.coreutils pkgs.util-linux]}"
    for i in $(seq 1 30); do
      ip route show dev ${cfg.server.tunDevice} 2>/dev/null | grep -q . && break
      sleep 1
    done
    if ! ip route show dev ${cfg.server.tunDevice} 2>/dev/null | grep -q .; then
      logger -t tuvpn "tun device ${cfg.server.tunDevice} never carried routes; not advertising"
      exit 1
    fi
    for i in $(seq 1 30); do
      tailscale ip -4 >/dev/null 2>&1 && break
      sleep 1
    done
    if ! tailscale set --advertise-routes=${routeCsv}; then
      logger -t tuvpn "tailscale set --advertise-routes failed (tailscaled not up?)"
      exit 1
    fi
    logger -t tuvpn "advertised ${routeCsv} to the tailnet"
  '';

  # ExecStopPost runs on EVERY stop, including the one that precedes a Restart=always
  # re-dial: the advertisement blinks out and the next ExecStartPost puts it back. A stale
  # advertisement pointing at a dead tunnel is the blackhole this mode cannot tolerate
  # (the laptop's accept-routes would happily keep sending into it), so clearing is the
  # default and keeping is the exception.
  tuvpn-unadvertise = pkgs.writeShellScript "tuvpn-unadvertise" ''
    export PATH="${lib.makeBinPath [tsBin pkgs.util-linux]}"
    tailscale set --advertise-routes= 2>/dev/null || true
  '';

  masqRules =
    (builtins.concatMap (src: [
        ''iptables -w -t nat -A POSTROUTING -s ${src} -o ${cfg.server.tunDevice} -j MASQUERADE''
        ''iptables -w -A FORWARD -i tailscale0 -o ${cfg.server.tunDevice} -s ${src} -j ACCEPT''
      ])
      cfg.server.forwardFrom)
    ++ [
      # One return-path rule for the lot (transit replies ride conntrack, microvm-host shape).
      ''iptables -w -A FORWARD -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT''
    ];

  masqStopRules =
    (builtins.concatMap (src: [
        ''iptables -w -t nat -D POSTROUTING -s ${src} -o ${cfg.server.tunDevice} -j MASQUERADE 2>/dev/null || true''
        ''iptables -w -D FORWARD -i tailscale0 -o ${cfg.server.tunDevice} -s ${src} -j ACCEPT 2>/dev/null || true''
      ])
      cfg.server.forwardFrom)
    ++ [
      ''iptables -w -D FORWARD -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true''
    ];
in {
  options = {
    MODULES.networking.tuvpn = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable the TU Wien VPN client helper (tuvpn-connect)";
      };

      viaHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hp";
        description = ''
          Name of a fleet host running MODULES.networking.tuvpn.server whose tunnel to
          route TU traffic through. Renders tuvpn-via-<host> (on/off/toggle/restart/status,
          driving the remote unit over tailnet SSH as root and flipping
          `tailscale set --accept-routes` locally), its wofi menu, and a desktop entry.
          The host must have MODULES.networking.tuvpn.server.enable, a tailscale hostIP,
          and accept key-only root SSH from this box (the deploy path already does).
          Pair this with MODULES.networking.dns.splitDns.acceptRoutes = false on the
          client host so the declarative tailscale state matches the toggle's OFF default.
        '';
      };

      secretOwner = lib.mkOption {
        type = lib.types.str;
        default = "akos";
        description = "Owner of the tu/vpn/* secrets (root on a headless server - e.g. hp has no akos uid).";
      };

      secretGroup = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = "Group of the tu/vpn/* secrets.";
      };

      server = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run openconnect as a root systemd unit (tuvpn.service) on this host and
            forward tailnet transit into it. Not wantedBy boot unless startAtBoot is set -
            the tuvpn-via-* toggles start it on demand. Runs as root: it needs tun, and
            no jail applies (a WAN-side TLS client, not a tailnet service; it needs no
            service-graph edge - the SG-INPUT chain is INPUT-scoped and this traffic only
            traverses FORWARD. The Suricata tap DOES see the transit SYNs on tailscale0
            and logs SG-DRIFT for ports outside the edge table - harmless in log-only
            mode, revisit before enforce).
          '';
        };

        gateway = lib.mkOption {
          type = lib.types.str;
          default = "vpn.tuwien.ac.at";
          description = "AnyConnect gateway address.";
        };

        profile = lib.mkOption {
          type = lib.types.str;
          default = "1_TU_getunnelt";
          description = ''
            AnyConnect authgroup. Keep a split profile: "2_Alles_getunnelt" would move
            THIS host's own default route into the tunnel and put every service on the
            box behind the university's egress the moment the gateway hiccups.
          '';
        };

        noDtls = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            --no-dtls, mirroring the working client. DTLS over hp's clean lab leg would
            actually be viable and cheaper under loss, but the TCP datachannel is proven;
            flip to false only with measurements.
          '';
        };

        tunDevice = lib.mkOption {
          type = lib.types.str;
          default = "tun0";
          description = "Tunnel device name (pinned via --tun-device so the FORWARD/NAT rules and the advertise gate name it exactly).";
        };

        startAtBoot = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            wantedBy multi-user.target. Off by default: the tunnel is on-demand and the
            account's fixed VPN address should not be held while nobody uses it. Set true
            only if TU's session policy makes the on-demand dance pointless.
          '';
        };

        tuPrefixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            # TU Wien's registered aggregate. SOURCE OF TRUTH is the split-include the
            # gateway actually pushes: on first bring-up run `ip route show dev tun0` on
            # the server host and extend this list (as an option value - the litmus-test
            # location for the fact is here, it is a TU fact, not an hp fact). The VPN
            # profile is named "TU_getunnelt" precisely because it pushes TU's own
            # space; the public remainder of 128.130/16 is reachable from the lab WAN
            # anyway, forwarding just falls through to it.
            "128.130.0.0/16"
          ];
          description = ''
            CIDRs advertised to the tailnet as subnet routes while the tunnel is up, and
            nothing else (tailscale rejects prefixes overlapping 100.64.0.0/10, so a
            private range from the split-include that collides must be rewritten, not
            advertised). This is the whole forwarding contract: clients accept these
            routes, transit them here, and they leave with the VPN address.
          '';
        };

        forwardFrom = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["100.64.0.0/10"];
          description = ''
            Sources the host will MASQUERADE into the tunnel and ACCEPT in FORWARD.
            The tailnet-wide default is honest for a single-owner tailnet but remember
            the exit-node advertisement: any peer that later selects this box as exit
            also reaches these prefixes. Narrow to per-host /32s to forbid that.
          '';
        };
      };
    };
  };

  config = lib.mkMerge [
    # ---------------------------------------------------------------- secrets ---------------
    # Defined ONCE for both consumers - client and server branches writing the same
    # sops.secrets.<name> twice is the "attribute already defined" trap (AGENTS.md).
    # The sops recipient set (sops/.sops.yaml) already covers every host's age key, so
    # enabling the server half needs no re-encryption.
    (lib.mkIf (cfg.enable || cfg.server.enable) {
      MODULES.security.sops.enable = true;
      sops.secrets."tu/vpn/user" = {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      };
      sops.secrets."tu/vpn/pass" = {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      };
      sops.secrets."tu/vpn/totp" = {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      };
    })

    # ---------------------------------------------------------------- client ----------------
    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        tuvpn-connect
        tuvpn-connect-desktop
      ];

      security.sudo.extraRules = [
        {
          users = ["akos"];
          commands = [
            {
              command = "${pkgs.openconnect}/bin/openconnect";
              options = ["NOPASSWD"];
            }
            {
              command = "${pkgs.psmisc}/bin/killall openconnect";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
    })

    # ------------------------------------------------------- client via server host ---------
    (lib.mkIf (cfg.viaHost != null) {
      assertions = [
        {
          assertion = viaIP != null;
          message = "MODULES.networking.tuvpn.viaHost = \"${cfg.viaHost}\" but that host has no MODULES.networking.tailscale.hostIP - the toggle script bakes its tailnet address in.";
        }
      ];

      environment.systemPackages = [
        tuvpn-via
        tuvpn-via-menu
        tuvpn-via-desktop
      ];

      # Exact-command rules (the repo's sudo pattern): the tailscale socket is root-only,
      # so even the status read needs sudo; the toggle script calls precisely these
      # argument spellings.
      security.sudo.extraRules = [
        {
          users = ["akos"];
          commands = [
            {
              command = "${tsBin}/bin/tailscale status --json";
              options = ["NOPASSWD"];
            }
            {
              command = "${tsBin}/bin/tailscale set --accept-routes=true";
              options = ["NOPASSWD"];
            }
            {
              command = "${tsBin}/bin/tailscale set --accept-routes=false";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
    })

    # ---------------------------------------------------------------- server ----------------
    (lib.mkIf cfg.server.enable {
      assertions = [
        {
          assertion = config.services.tailscale.enable;
          message = "MODULES.networking.tuvpn.server advertises subnet routes with `tailscale set` and must run on a tailscale node.";
        }
        {
          # The toggle script and this unit are one contract - they must agree on the
          # service name and the prefix list.
          assertion = cfg.server.tuPrefixes != [];
          message = "MODULES.networking.tuvpn.server.tuPrefixes is empty - the tunnel would carry nothing and advertise nothing.";
        }
      ];

      boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

      systemd.services.tuvpn = {
        description = "TU Wien VPN tunnel (AnyConnect) serving tailnet transit to ${routeCsv}";
        after = [
          "network-online.target"
          "tailscaled.service"
          # sops-install-secrets.service is transient (see cloudflare.nix); ordering matters
          # when the unit is (re)started by an activation, and the toggle ssh-starts it at
          # arbitrary times, when the secrets are long in place.
          "sops-install-secrets.service"
        ];
        wants = ["network-online.target"];
        wantedBy = lib.optionals cfg.server.startAtBoot ["multi-user.target"];
        # A dead gateway (outage, wrong OTP window) must never trip the start-limit and
        # strand the unit in failed - the toggle expects `systemctl start` to eventually
        # mean "connected" or block/fail visibly, not "permanently given up".
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "simple";
          # 0700 root: the creds file (password + one live OTP window) lives here and is
          # wiped by systemd when the unit stops (RuntimeDirectory cleanup).
          RuntimeDirectory = "tuvpn";
          RuntimeDirectoryMode = "0700";
          ExecStartPre = "${tuvpn-creds}";
          ExecStart = "${tuvpn-exec}";
          ExecStartPost = "${tuvpn-advertise}";
          ExecStopPost = "${tuvpn-unadvertise}";
          Restart = "always";
          RestartSec = "10s";
          # covers both ExecStartPre/ExecStart dial time and the 2x30s polls in post.
          TimeoutStartSec = "3min";
          ProtectHome = true;
        };
      };

      # NAT + forwarding for tailnet transit, mirroring modules/vm/microvm-host.nix's shape
      # (the firewall flushes the chains before extraCommands run, so -A/-D stay idempotent;
      # FORWARD default here is the kernel's ACCEPT, the explicit rules are what survive the
      # day the default flips). Only tailscale0's sources are masqueraded - the tunnel never
      # carries this host's own traffic under the split profile anyway.
      networking.firewall = {
        extraCommands = lib.concatStringsSep "\n" masqRules;
        extraStopCommands = lib.concatStringsSep "\n" masqStopRules;
      };
    })
  ];
}
