# TU Wien VPN, three cooperating halves (designed 2026-11-03):
#
#   client   (cfg.enable)              - the interactive wofi helper + sudo rules. Lives on the
#                                        desktop (legion5) and stays the fastest path while
#                                        physically on/near campus. With viaHost set, the
#                                        SINGLE "TU VPN" wofi entry is tuvpn-menu: it offers
#                                        both paths, and every selection tears down BOTH
#                                        (local openconnect + the remote unit + accept-routes)
#                                        before connecting the chosen one, so exactly one
#                                        path is ever live.
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
  # The profile may be passed as $1 (tuvpn-menu's non-interactive path: then openconnect
  # --backgrounds and the script returns with the dial's exit code, so the menu can notify
  # and close instead of owning a foreground VPN forever). No argument keeps the original
  # interactive wofi picker for terminal/desktop use.
  tuvpn-connect = pkgs.writeShellScriptBin "tuvpn-connect" ''
    set -euo pipefail

    VPN_HOST="vpn.tuwien.ac.at"

    PROFILE="''${1:-}"
    DAEMON=""
    if [[ -z "$PROFILE" ]]; then
      PROFILE=$(printf "1_TU_getunnelt\n2_Alles_getunnelt\nDisconnect\n" | \
        ${pkgs.wofi}/bin/wofi --dmenu --prompt="Select VPN profile" --lines=3)

      if [[ -z "$PROFILE" ]]; then
        echo "No profile selected, aborting." >&2
        exit 1
      fi
    else
      DAEMON="--background"
    fi

    # Kill ANY local openconnect first, including a stale foreground one from the desktop
    # entry - this is also the menu's "disconnect" path (tuvpn-connect Disconnect).
    # stderr silenced: "no process found" is the common case (nothing was up) and would
    # otherwise leak into the menu's captured OUT as scary noise.
    sudo ${pkgs.psmisc}/bin/killall openconnect 2>/dev/null || true

    if [[ "$PROFILE" == "Disconnect" ]]; then
      echo "Disconnected from $VPN_HOST."
      exit 0
    fi

    USER=$(cat ${config.sops.secrets."tu/vpn/user".path})
    PASS=$(cat ${config.sops.secrets."tu/vpn/pass".path})
    TOTP_SECRET=$(cat ${config.sops.secrets."tu/vpn/totp".path})

    OTP=$(${pkgs.oath-toolkit}/bin/oathtool --totp -b "$TOTP_SECRET")

    echo "Connecting to $VPN_HOST with profile '$PROFILE'..."

    # --background daemonizes, but the DAEMON keeps writing its session log to stdout -
    # left attached it pins any caller's pipe open (the menu's $(...) capture hung forever
    # while the tunnel was actually up, legion5 2026-11-06). In $1/daemon mode detach the
    # log into a per-user file; the interactive foreground path keeps the terminal.
    oc-dial() {
      printf '%s\n%s\n' "$PASS" "$OTP" | \
        sudo ${pkgs.openconnect}/bin/openconnect \
          --protocol=anyconnect \
          --no-dtls \
          --no-external-auth \
          --authgroup="$PROFILE" \
          --user="$USER" \
          --passwd-on-stdin \
          $DAEMON \
          "$VPN_HOST"
    }

    if [[ -n "$DAEMON" ]]; then
      oc-dial >>"/tmp/tuvpn-$(id -u).log" 2>&1
    else
      oc-dial
    fi
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
  viaHostKeys = viaTarget.config.MODULES.networking.tuvpn.server.hostKeys or [];
  # Same cross-flake read as viaIP/viaHostKeys: the toggle's state probe needs to know
  # WHICH prefixes to look for in the local routing table (see ENABLED below).
  viaTuPrefixes = viaTarget.config.MODULES.networking.tuvpn.server.tuPrefixes or [];

  tuvpn-via = pkgs.writeShellScriptBin "tuvpn-via-${cfg.viaHost}" ''
    set -uo pipefail

    TS="${tsBin}/bin/tailscale"
    # The host key comes from the declaratively-pinned /etc file (server.hostKeys on the
    # target), NOT from any user's known_hosts - the toggle runs from the desktop menu on a
    # box where nobody has ever interactively ssh'd to the tailnet IP, and BatchMode answers
    # "are you sure you want to continue connecting?" with exactly one "Host key
    # verification failed". GlobalKnownHostsFile is neutralised for the same reason:
    # deterministic auth or a clear error, never a per-host-state surprise.
    SSH="${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/tuvpn/ssh-known-hosts -o GlobalKnownHostsFile=/dev/null -o ForwardX11=no root@${viaIP}"
    VIA="${cfg.viaHost}"
    IP="${pkgs.iproute2}/bin/ip"
    GREP="${pkgs.gnugrep}/bin/grep"
    # The prefixes whose transit this toggle owns, baked from the target's config.
    PREFIXES="${lib.concatStringsSep " " viaTuPrefixes}"

    # Accept-state proxy = the KERNEL routing table, not tailscale's status JSON:
    # measured 2026-11-06 on legion5 (tailscale 1.104.4) that SecondaryRoutes is
    # ABSENT and Self.AcceptRoutes null even with accept-routes ON and the routes
    # installed - the old SecondaryRoutes[].Enabled probe therefore printed
    # "none advertised" (and left `toggle` permanently seeing OFF) while pings
    # answered through the tunnel. `ip route get` asks the kernel the same question
    # a ping answers (which device would this packet leave on), so it cannot desync
    # from reality; tailscaled installs accepted secondary routes there and pulls
    # them on --accept-routes=false (both directions verified). Needs no sudo. The
    # .1 host inside each prefix hits the route without needing a live target.
    routed-one() {
      probe="''${1%%/*}"
      probe="''${probe%.*}.1"
      $IP route get "$probe" 2>/dev/null | $GREP -q 'dev tailscale0'
    }
    routed-count() {
      n=0
      for p in $PREFIXES; do
        routed-one "$p" && n=$((n+1))
      done
      echo $n
    }
    ENABLED=$(routed-count)

    case "''${1:-status}" in
      on)
        # Order is load-bearing: hp starts first (its ExecStartPost returns only once the
        # tunnel is up and the routes are advertised), the laptop accepts second. Accepting
        # before the tunnel exists would blackhole TU-bound packets into a dead next-hop.
        # A failed FIRST start is not fatal: TU allows max 3 concurrent sessions per user,
        # and the gateway holds the slot for tens of seconds after a killall/teardown, so
        # switching modes (the combined menu's disconnect-both-then-connect path, measured
        # 2026-11-06) reliably loses the first dial to "Es sind maximal 3 gleichzeitige
        # VPN-Verbindungen" - while hp's Restart=always re-dials ~10s later and wins. Poll
        # is-active through that window instead of aborting on the first return.
        STARTED=0
        $SSH systemctl start tuvpn >/dev/null 2>&1 && STARTED=1
        if [ "$STARTED" -eq 0 ]; then
          for i in $(seq 1 12); do
            sleep 5
            if [ "$($SSH systemctl is-active tuvpn 2>/dev/null)" = "active" ]; then STARTED=1; break; fi
          done
        fi
        if [ "$STARTED" -eq 0 ]; then
          echo "could not start tuvpn on $VIA - TU may be holding your session slots (max 3 concurrent, https://nix.kom.tuwien.ac.at/vpn-sessions), or the unit fails for another reason: ssh root@$VIA journalctl -u tuvpn -b | tail -20" >&2
          exit 1
        fi
        sudo $TS set --accept-routes=true
        # The ExecStartPost gate advertises asynchronously after Type=simple's start job
        # can already report success in edge cases; wait for the routes to actually ride
        # the tailnet so "ON" never means "blackhole".
        for i in $(seq 1 24); do
          [ "$(routed-count)" -gt 0 ] && break
          sleep 5
        done
        echo "ON - TU routes via $VIA"
        ;;
      off)
        # Mirror order: stop accepting first, then tear the tunnel down.
        sudo $TS set --accept-routes=false
        $SSH systemctl stop tuvpn >/dev/null 2>&1 || true
        echo "OFF"
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
        # ONE compact line: <state> <routed>/<total> <detail>. The menu turns state into
        # a colored notification; the CLI gets the same line. The old verbose per-prefix
        # prose made the notification 5x taller than the screen for information nobody
        # acts on (legion5 2026-11-06: "make it shorter"). routed-one already IS the
        # per-prefix answer, so a count says everything; the only case where prefixes
        # differ from each other is a partial tailnet flap, which self-heals.
        HP=$($SSH systemctl is-active tuvpn 2>/dev/null) || HP="''${HP:-ssh-unreachable}"
        N=0; T=0
        for p in $PREFIXES; do
          T=$((T+1))
          routed-one "$p" && N=$((N+1))
        done
        if [ "$N" -gt 0 ]; then
          echo "routed $N/$T on $VIA"
        elif [ "$HP" = "ssh-unreachable" ]; then
          echo "ssh-unreachable 0/$T (no tailnet ssh to $VIA)"
        elif [ "$HP" != "active" ]; then
          echo "down 0/$T ($VIA unit: $HP)"
        else
          # unit up but nothing routed: either accept-routes is off or the control plane
          # has not approved $VIA's advertisement - the two things `on` / autoApprovers fix.
          echo "not-accepted 0/$T ($VIA up, routes not installed)"
        fi
        ;;
      *)
        echo "usage: tuvpn-via-$VIA {on|off|toggle|restart|status}" >&2
        exit 2
        ;;
    esac
  '';

  # (The old tuvpn-via-<host>-menu and its desktop entry were replaced 2026-11-06 by the
  # single tuvpn-menu below, which owns both paths; tuvpn-connect lost its own desktop
  # entry for the same reason - one "TU VPN" launcher, not three that fight each other.)

  # ------------------------------------------------------------- combined menu -------------
  # One wofi entry holding BOTH paths (direct openconnect and via-<host> transit), added
  # 2026-11-06 because juggling two desktop entries kept leaving the other mode half-live:
  # a direct tunnel running while accept-routes pointed at hp blackholed nothing only by
  # luck (the local tun stole the default-ish TU routes first), and nobody remembered
  # which knob was up. Contract: EVERY selection tears down BOTH modes first
  # (killall openconnect + tuvpn-via off), then connects the chosen one - so exactly
  # one path is ever active, and "Disconnect" is the same teardown with nothing after.
  # Local connects run openconnect --background (tuvpn-connect's non-interactive $1
  # mode) so the menu can report the result via notify and exit; a foreground VPN
  # would pin a phantom terminal forever with terminal=false. tuvpn-menu itself takes
  # the choice as $1 too, which makes the contract scriptable (and testable).
  tuvpn-menu = pkgs.writeShellScriptBin "tuvpn-menu" ''
            set -uo pipefail

            CONNECT="${tuvpn-connect}/bin/tuvpn-connect"
            VIA="${tuvpn-via}/bin/tuvpn-via-${cfg.viaHost}"

            # $1 skips wofi with the exact menu label - the same script drives terminal use and
            # testing, and wofi stays the interactive default.
            CHOICE="''${1:-}"
            if [ -z "$CHOICE" ]; then
              CHOICE=$(printf "1_TU_getunnelt (direct)\n2_Alles_getunnelt (direct)\nVia ${cfg.viaHost} (tailnet transit)\nStatus\nDisconnect\n" | \
                ${pkgs.wofi}/bin/wofi --dmenu --prompt="TU VPN" --lines=5) || exit 1
            fi

            teardown-all() {
              # Order: tailnet accept first (kills the blackhole-into-dead-hp window), then the
              # remote unit, then any local openconnect. All idempotent.
              $VIA off >/dev/null 2>&1 || true
              $CONNECT Disconnect >/dev/null 2>&1 || true
            }

            # Every branch sets ICON+LINE (and BODY only when there is something left to
            # say). Emoji carry the color: quickshell's notification daemon ignores markup,
            # and \033 codes render as garbage - a colored dot is the only "color" that is
            # guaranteed to survive to the screen. Body is ONE short line; the old format
            # stacked status prose three deep for information nobody acts on.
            case "$CHOICE" in
              *" (direct)")
                PROFILE="''${CHOICE% (direct)}"
                teardown-all
                OUT=$($CONNECT "$PROFILE" 2>&1) && { ICON="🟢"; LINE="direct VPN up ($PROFILE)"; } || { ICON="🔴"; LINE="direct VPN failed"; BODY=$(echo "$OUT" | ${pkgs.coreutils}/bin/tail -1); }
                ;;
              "Via ${cfg.viaHost} (tailnet transit)")
                teardown-all
                OUT=$($VIA on 2>&1) && { ICON="🟢"; LINE="VPN up via ${cfg.viaHost}"; } || { ICON="🔴"; LINE="via ${cfg.viaHost} failed"; BODY=$(echo "$OUT" | ${pkgs.coreutils}/bin/tail -1); }
                ;;
              "Status")
                ${pkgs.procps}/bin/pgrep -x openconnect >/dev/null 2>&1 && D="🟢 direct" || D="⚪ direct"
                HP=$($VIA status 2>&1)
                set -- $HP   # $1=state word ($2=routed-count) of the toggle's one-line status
                case "$HP" in
                  routed*)       ICON="🟢"; V="🟢 via ${cfg.viaHost} ($2 routed)" ;;
                  not-accepted*) ICON="🟡"; V="🟡 via ${cfg.viaHost} (up, not accepted)" ;;
                  *)             ICON="⚪"; V="⚪ via ${cfg.viaHost} ($1)" ;;
                esac
                LINE="$D  |  $V"
                ;;
              "Disconnect")
                teardown-all
                ICON="⚪"; LINE="all VPNs down"
                ;;
              *)
                exit 1
                ;;
            esac

            echo "$ICON $LINE''${BODY:+ - $BODY}"
            ${pkgs.libnotify}/bin/notify-send -t 6000 "$ICON TU VPN" "$LINE''${BODY:+
    $BODY}" || true
  '';

  tuvpn-menu-desktop = pkgs.makeDesktopItem {
    name = "tuvpn-menu";
    desktopName = "TU VPN";
    comment = "TU Wien VPN - direct or via ${cfg.viaHost} (selecting either disconnects both first)";
    icon = "network-vpn";
    exec = "${tuvpn-menu}/bin/tuvpn-menu";
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
      --interface=${cfg.server.tunDevice} \
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
  # just fails). PATH must name every binary the script uses - including grep: systemd gives
  # ExecStartPost no useful default PATH, and a bare `grep` here once spun the poll loop on
  # "command not found" (hp 2026-11-06) until the gate exit-1'd on "never carried routes".
  tuvpn-advertise = pkgs.writeShellScript "tuvpn-advertise" ''
    export PATH="${lib.makeBinPath [tsBin pkgs.iproute2 pkgs.coreutils pkgs.util-linux pkgs.gnugrep]}"
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
          description = "Tunnel device name (pinned via --interface so the FORWARD/NAT rules and the advertise gate name it exactly; this openconnect has no --tun-device - hp 2026-11-06 usage error).";
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
            # TU's split-include exactly as the gateway pushes it (measured on hp
            # 2026-11-06, profile 1_TU_getunnelt, `ip route show dev tun0`):
            #   128.130.0.0/15  - TU's whole 128.130+128.131 space, which also
            #                     contains the 128.131.236.0/22 pool the gateway
            #                     hands VPN addresses from (hp's tun0 today:
            #                     128.131.237.235)
            #   193.170.72.0/21 - TU's other internal aggregate
            # Advertise exactly this set: the gateway only routes what it pushes,
            # so anything wider blackholes at TU's side, and the old 128.130.0.0/16
            # guess silently missed 128.131 + 193.170.72/21 transit (hp 2026-11-06).
            # SOURCE OF TRUTH stays the push - re-measure `ip route show dev tun0`
            # after any TU policy change (the private-collision caveat below still
            # applies).
            "128.130.0.0/15"
            "193.170.72.0/21"
          ];
          description = ''
            CIDRs advertised to the tailnet as subnet routes while the tunnel is up, and
            nothing else (tailscale rejects prefixes overlapping 100.64.0.0/10, so a
            private range from the split-include that collides must be rewritten, not
            advertised). This is the whole forwarding contract: clients accept these
            routes, transit them here, and they leave with the VPN address. Every prefix
            new here must also be APPROVED on the tailnet control plane (admin console
            "Approve routes" or ACL autoApprovers.routes) - an advertised-but-unapproved
            route is exactly the "none advertised" a client sees while `systemctl show
            tuvpn` says active.
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

        hostKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["100.92.36.52 ssh-ed25519 AAAAC3..."];
          description = ''
            This host's SSH public host keys as known_hosts lines, keyed by its Tailscale
            IP (the address the tuvpn-via-* scripts connect to). Set on the SERVER host;
            clients read it across the flake and pin it in /etc/tuvpn/ssh-known-hosts, so
            the toggle authenticates the tunnel host without any user ever having
            interactively ssh'd there. Public material, safe to commit; refresh after any
            ssh host-key regeneration (ssh-keyscan <tailnet-ip> over the tailnet).
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
      # tuvpn-connect stays the CLI (and the menu's direct-path driver). Its standalone
      # desktop entry only ships when there is NO viaHost: with one configured, tuvpn-menu
      # below is the single "TU VPN" launcher and a second identically-named entry would be
      # pure confusion.
      environment.systemPackages =
        [tuvpn-connect]
        ++ lib.optionals (cfg.viaHost == null) [tuvpn-connect-desktop];

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
        {
          assertion = viaHostKeys != [];
          message = "MODULES.networking.tuvpn.viaHost = \"${cfg.viaHost}\" but ${cfg.viaHost} declares no MODULES.networking.tuvpn.server.hostKeys - the toggle would have nothing to pin and every ssh would die at host key verification.";
        }
        {
          # The combined menu's direct path (and the tailscale sudo rules) live in the
          # client branch; a viaHost-only host would render a menu whose entries 1-3 die
          # on missing secrets and sudo rules.
          assertion = cfg.enable;
          message = "MODULES.networking.tuvpn.viaHost needs MODULES.networking.tuvpn.enable = true: the combined menu's direct path and the tailscale sudo rules live in the client branch.";
        }
      ];

      # Public host keys of the tunnel host, pinned for the toggle's ssh. Read from the
      # flake (syncthing.deviceID's pattern): the key is the server's own fact, declared
      # once there, and clients never restate it.
      environment.etc."tuvpn/ssh-known-hosts".text = lib.concatStringsSep "\n" viaHostKeys + "\n";

      # One launcher for both paths (the menu also drives tuvpn-connect's direct mode,
      # whose sudo rules live in the client branch above - asserted).
      environment.systemPackages = [
        tuvpn-via
        tuvpn-menu
        tuvpn-menu-desktop
      ];

      # Exact-command rules (the repo's sudo pattern): the tailscaled socket is root-only,
      # so flipping accept-routes goes through sudo; the toggle script calls precisely
      # these argument spellings. (The old `tailscale status --json` rule died with the
      # SecondaryRoutes probe - the kernel routing table replaced it and needs no sudo,
      # 2026-11-06.)
      security.sudo.extraRules = [
        {
          users = ["akos"];
          commands = [
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
