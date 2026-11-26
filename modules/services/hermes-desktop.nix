# Hermes' virtual desktop + browser workstation on hp (owner ask 2026-11-20:
# "a simple desktop environment, full access to its own environment, remotely
# viewable in my browser, so Hermes competes with ChatGPT-desktop computer
# use"): Xvfb :99 -> openbox -> x11vnc (loopback RFB, password from sops) ->
# websockify/noVNC -> Traefik as https://hermes-desktop.hp, so the human
# WATCHES the agent work live from any browser. On the same display a
# Playwright-MCP server runs as an HTTP service and Hermes attaches to it as
# a url MCP server: browser_navigate/click/screenshot drive a REAL headed
# Chromium inside the desktop - ChatGPT-computer-use parity, plus the edge
# they do not ship: the browser is a window on a VNC session the owner can
# grab at any moment, and every process of it runs behind the hermes-egress
# uid chain like everything else Hermes does.
#
# Why Xvfb+x11vnc and not TigerVNC's Xvnc: Xvnc has no local unix socket, so
# every X client would dial DISPLAY over loopback TCP - and the hermes-egress
# jail REJECTs loopback TCP outside its allowlist, which would mean widening
# it for the agent. Xvfb's /tmp/.X11-unix/X99 socket is what the agent
# reaches (bind-mounted into its PrivateTmp), and x11vnc's one TCP listener
# (127.0.0.1:PORTS.hermesVnc) is dialled ONLY by the noVNC proxy - which
# deliberately runs under its OWN uid (DynamicUser): the egress chain is
# uid-owner-matched on the hermes uid, so a websockify proxy of the hermes
# uid would itself be REJECTed from dialing 5901. The proxy touches no
# Hermes state, so the uid split costs nothing.
#
# Why a standalone playwright HTTP unit and not MODULES.services.playwrightMcp
# (the legion5 stdio feed): that module exists for omp and switches OFF omp's
# native browser prelude to survive; hp runs no omp at all, and Hermes wants
# a PERSISTENT headed browser - one Chromium, one profile, surviving every
# gateway restart and visible in VNC - which is exactly what stdio-per-session
# cannot be. Hermes' url-transport mcpServers (verified in the pinned fork:
# moduleCommon.nix's mcpServerType, used by matrix-reader already) dials it.
# The two hosts' needs genuinely differ (Rule 2's documented-reason clause).
#
# Egress audit (measured pieces marked): playwright talks to its Chromium
# over pipes, not a loopback TCP CDP port (Playwright's launch transport;
# `--cdp-endpoint` connect mode is NOT used), so no ephemeral loopback holes.
# The ONE port the agent dials is PORTS.hermesPlaywright, admitted through
# hermes-agent's own extraAllowedLoopbackPorts option. Chromium's outbound
# web traffic rides hermes-egress exactly like the agent's (public yes,
# tailnet/LAN/private no). If a playwright release ever starts dialing the
# browser over loopback TCP, the symptom is MCP tools failing to connect with
# `egress-deny-hermes` LOG lines; the fix is the gateway-api sub-chain trick.
#
# Chromium launches with playwright's DEFAULT chromiumSandbox=false (upstream
# API default), which is what makes it work under DevicePolicy=closed +
# CapabilityBoundingSet="" + RestrictNamespaces: no setuid helper, no user
# namespaces, software GL (llvmpipe) through PrivateDevices' bare /dev.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit (lib) literalExpression mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.hermes-desktop;
  hermes = config.services.hermes-agent;
  hermesHome = "${hermes.stateDir}/.hermes";
  # The fleet Hermes sandbox attrset, exported by hermes-agent.nix for exactly
  # this reuse (paseo-hermes precedent): the browser's filesystem world must
  # equal the agent's, so screenshots saved under HERMES_HOME are readable by
  # the agent's terminal() and nothing outside leaks in.
  sandbox = config.MODULES.services.hermes-agent.paseoHermesSandbox;

  # The desktop's binaries: what the units run, plus what the AGENT gets on
  # its PATH (xdotool/xclip/scrot are its hands; the office kit - soffice,
  # the docx/xlsx CLIs - arrives through agentDocuments, and LibreOffice
  # renders right on this display for `soffice` GUI mode).
  desktopTools = with pkgs; [
    xorg.xvfb
    x11vnc
    openbox
    xterm
    mousepad
    pcmanfm
    xdotool # keyboard/mouse onto real windows (computer use beyond the browser)
    xclip # clipboard bridge between the agent's shell and the desktop apps
    wmctrl
    scrot # whole-desktop screenshots (the browser side has its own)
    imagemagick # convert for post-processing captures
    pkgs.novnc
  ];

  # websockify + noVNC web files need python3 from the closure the novnc
  # launcher script references; running it DynamicUser keeps it OUT of the
  # hermes uid's egress chain (see the header).
  novncLauncher = pkgs.novnc;
in {
  options.MODULES.services.hermes-desktop = {
    enable = mkEnableOption ''
      Hermes' virtual desktop: Xvfb + openbox on display :99 as the hermes
      service user, x11vnc (loopback, sops password) exported to the browser
      through websockify/noVNC behind Traefik (https://hermes-desktop.hp on
      the tailnet), plus a Playwright-MCP HTTP server driving a headed
      Chromium on that display and offered to Hermes as a url MCP server
    '';

    display = mkOption {
      type = types.ints.unsigned;
      default = 99;
      description = "X display number; the socket is /tmp/.X11-unix/X<display> and DISPLAY=:<display> everywhere.";
    };

    resolution = mkOption {
      type = types.str;
      default = "1600x1000";
      description = ''
        Screen size. 1600x1000 fits a laptop browser tab without scaling and
        keeps Xvfb's framebuffer (1600*1000*4 ~ 6.4 MB, plus Chromium's tile
        caches) well inside the LIMITS rows.
      '';
    };

    vncPasswordSecret = mkOption {
      type = types.str;
      default = "hermes/desktop_vnc_password";
      description = ''
        sops key holding the VNC Challenge password. Mounted 0400 for the
        x11vnc unit's uid (x11vnc's -passwdfile takes the PLAINTEXT file and
        hashes per RFB VncAuth internally - unlike TigerVNC there is no
        vncpasswd -f prepass). This is the desktop's actual auth gate: the
        HTTP leg behind Traefik is tailnet-only (fleet doctrine), but the VNC
        password also gates anything reaching 5901, and rotation is
        `sops set` + switch.
      '';
    };

    playwrightPackage = mkOption {
      type = types.package;
      default = pkgs-unstable.playwright-mcp;
      defaultText = literalExpression "pkgs-unstable.playwright-mcp";
      description = ''
        The @playwright/mcp served as the HTTP MCP server. Deliberately the
        UNSTABLE set: the 0.0.69 the nixos-26.05 pin carries predates
        --shared-browser-context (the one-browser-for-all-clients flag this
        unit needs, else every MCP re-attach forks a fresh headed window on
        the desktop) and --caps vision. Unstable 0.0.83 (both flags + /mcp
        streamable-HTTP + legacy /sse verified live on this lock 2026-11-20)
        is what legion5's stdio feed should also move to at the next nixpkgs
        bump; here it is load-bearing now.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["--device" "iPhone 15"];
      description = "Extra playwright-mcp flags, appended verbatim to the served command.";
    };

    apps = mkOption {
      type = types.listOf types.package;
      default = desktopTools;
      defaultText = literalExpression "the module's desktop tool set (module body)";
      description = "Installed, on every desktop unit's PATH, AND fed to the hermes units' PATH (hermes-agent.extraPackages) - xdotool/scrot/xclip are the agent's hands on this display.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.services.hermes-agent.enable;
        message = "MODULES.services.hermes-desktop is Hermes' workstation; enable MODULES.services.hermes-agent on this host.";
      }
      {
        # The browser's filesystem world must equal the agent's sandbox -
        # hermes-agent.nix exports the attrset exactly for this (paseo-hermes
        # precedent). If upstream ever renames it, this fails at eval, not in
        # a half-open desktop.
        assertion = sandbox ? TemporaryFileSystem;
        message = "MODULES.services.hermes-agent.paseoHermesSandbox is missing/unshaped - hermes-desktop cannot reuse the Hermes sandbox.";
      }
    ];

    environment.systemPackages = cfg.apps;

    # VNC password: readable by the x11vnc unit's uid only (see the option).
    sops.secrets.${cfg.vncPasswordSecret} = {
      owner = hermes.user;
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      # The browser's XDG_RUNTIME_DIR (dbus/pulse sockets) + playwright's
      # profile and output area under the state dir (both inside the
      # sandbox's rw BindPaths, and the profile must survive restarts).
      "d /run/hermes-desktop 0700 ${hermes.user} ${hermes.group} -"
      "d ${hermesHome}/desktop 0700 ${hermes.user} ${hermes.group} -"
      # The X socket rendezvous dir lives on the HOST /tmp (Xvfb runs
      # without PrivateTmp so every unit's /tmp/.X11-unix BindPaths has a
      # real source). tmpfiles pre-creates it 1777 - Xvfb could create it
      # itself, but the other units' PrivateTmp namespaces expect the
      # mountpoint regardless of unit start order.
      "d /tmp/.X11-unix 1777 root root 30d"
    ];

    # --- the display ------------------------------------------------------------------
    # Xvfb runs WITHOUT PrivateTmp: its /tmp/.X11-unix/X99 socket IS the
    # rendezvous every other unit bind-mounts, so it lives on the host /tmp.
    systemd.services.hermes-xvfb = {
      description = "Hermes virtual X server (:${toString cfg.display})";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        User = hermes.user;
        Group = hermes.group;
        ExecStart = "${pkgs.xorg.xvfb}/bin/Xvfb :${toString cfg.display} -screen 0 ${cfg.resolution}x24 -nolisten tcp";
        Restart = "always";
        RestartSec = "5s";
        # No PrivateTmp: the /tmp/.X11-unix/X${display} socket IS the
        # cross-unit rendezvous every other desktop unit bind-mounts (see the
        # header's egress audit for why unix sockets and not TCP), so it must
        # live on the host /tmp. And the host /tmp must be WRITABLE: the old
        # comment here claimed ProtectSystem=strict "leaves /tmp alone" -
        # measured WRONG on hp 2026-11-24 (systemd 260.5, and /tmp is a plain
        # dir on zfs `/`, not a mount): strict mounts the ENTIRE hierarchy
        # read-only except /dev /proc /sys /run, so Xvfb died in a loop ("Could
        # not create lock file in /tmp/.tX99-lock", 1800+ restarts) and dragged
        # every Requires= hermes-* desktop unit down with it. Xvfb needs /tmp
        # for the lock AND the socket dir, so the wall gets exactly that hole.
        PrivateTmp = false;
        ReadWritePaths = ["/tmp"];
        # Xvfb takes no AF_INET (-nolisten tcp); AF_UNIX is the whole surface.
        RestrictAddressFamilies = ["AF_UNIX"];
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    systemd.services.hermes-openbox = {
      description = "Hermes desktop window manager";
      wantedBy = ["multi-user.target"];
      after = ["hermes-xvfb.service"];
      requires = ["hermes-xvfb.service"];
      environment = {
        DISPLAY = ":${toString cfg.display}";
        HOME = hermes.stateDir;
        XDG_RUNTIME_DIR = "/run/hermes-desktop";
      };
      serviceConfig = {
        User = hermes.user;
        Group = hermes.group;
        # No --session file: under ProtectSystem=strict openbox could not
        # write a first-run ~/.config/openbox anyway, and it falls back to
        # compiled-in defaults, which is all a WM on a head server needs.
        ExecStart = "${pkgs.openbox}/bin/openbox";
        Restart = "always";
        RestartSec = "5s";
        PrivateTmp = true;
        BindPaths = ["/tmp/.X11-unix"];
        ProtectSystem = "strict";
        # ProtectSystem=strict makes HOME read-only too (see the hermes-xvfb
        # unit's correction), and openbox DIES without its session cache dir
        # (hp 2026-11-24: "Unable to make directory
        # '/var/lib/hermes/.cache/openbox': Read-only file system" -> exit 1 ->
        # everything After= it crash-looped with it). The old comment below
        # only considered ~/.config/openbox (a soft fallback); ~/.cache is a
        # hard failure. stateDir is hermes-owned and the WM runs as hermes, so
        # opening exactly HOME is the same hole the agent's own units carry.
        ReadWritePaths = [hermes.stateDir];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = ["AF_UNIX"];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    # A live terminal on the desktop: the human who connects sees a shell
    # immediately, and it doubles as the escape hatch if the agent ever
    # wedges every window. Its child processes inherit the X socket bind.
    systemd.services.hermes-desktop-term = {
      description = "Hermes desktop terminal (xterm on :${toString cfg.display})";
      wantedBy = ["multi-user.target"];
      after = ["hermes-openbox.service"];
      path = cfg.apps;
      environment = {
        DISPLAY = ":${toString cfg.display}";
        HOME = hermes.stateDir;
        XDG_RUNTIME_DIR = "/run/hermes-desktop";
      };
      serviceConfig = {
        User = hermes.user;
        Group = hermes.group;
        ExecStart = "${pkgs.xterm}/bin/xterm -geometry 110x32+20+20 -hold";
        Restart = "on-failure";
        RestartSec = "10s";
        PrivateTmp = true;
        BindPaths = ["/tmp/.X11-unix" "/run/hermes-desktop"];
        ReadWritePaths = ["/run/hermes-desktop"];
        ProtectSystem = "strict";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = ["AF_UNIX"];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    # --- the human's window in (RFB -> WebSocket -> Traefik) ------------------------------
    systemd.services.hermes-x11vnc = {
      description = "Hermes desktop VNC server (127.0.0.1:${toString config.PORTS.hermesVnc})";
      wantedBy = ["multi-user.target"];
      after = ["hermes-xvfb.service"];
      requires = ["hermes-xvfb.service"];
      serviceConfig = {
        User = hermes.user;
        Group = hermes.group;
        # -localhost: RFB on loopback ONLY (the sole client is websockify).
        # -shared: a second viewer tab never forks the display.
        ExecStart = ''          ${pkgs.x11vnc}/bin/x11vnc \
                    -display :${toString cfg.display} \
                    -rfbport ${toString config.PORTS.hermesVnc} \
                    -localhost \
                    -passwdfile ${config.sops.secrets.${cfg.vncPasswordSecret}.path} \
                    -forever -shared -noxdamage -quiet'';
        Restart = "always";
        RestartSec = "5s";
        PrivateTmp = true;
        BindPaths = ["/tmp/.X11-unix"];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    # DynamicUser ON PURPOSE: the hermes-egress OUTPUT chain is
    # uid-owner-matched on the hermes uid, and its loopback policy REJECTs
    # 127.0.0.1:5901 - which is exactly what the proxy must dial. The proxy
    # has no business inside Hermes' filesystem jail anyway (it serves the
    # noVNC static files from the store and nothing else).
    systemd.services.hermes-novnc = {
      description = "Hermes desktop noVNC (web + websockify on 127.0.0.1:${toString config.PORTS.hermesNovnc})";
      wantedBy = ["multi-user.target"];
      after = ["hermes-x11vnc.service"];
      requires = ["hermes-x11vnc.service"];
      # The package's launcher health-checks its websockify child with
      # `ps -eo pid=` (novnc bin/novnc line ~213) - a bare unit PATH has no
      # procps, and the check died "ps: command not found" -> "Failed to
      # start WebSockets proxy" exit 1 even though websockify was proxying
      # fine (measured hp 2026-11-24: 40+ restarts). Unit-level `path` (the
      # shape hermes-desktop-term/playwright use); an accidental
      # serviceConfig.path just lands as a junk lowercase key.
      path = [pkgs.procps];
      serviceConfig = {
        DynamicUser = true;
        # The package's own launcher: websockify (bundled python) + mini-web
        # for vnc.html on ONE port. --heartbeat keeps idle tabs' websockets
        # alive under Traefik's defaults. No --timeout: x11vnc runs -forever
        # -shared (dead viewer sockets are its problem, not the proxy's), and
        # an idle-exit would also take the WEB SERVER down with the proxy -
        # the vnc.html page must be reachable even at 3am with nobody
        # connected.
        ExecStart = ''          ${novncLauncher}/bin/novnc \
                    --listen 127.0.0.1:${toString config.PORTS.hermesNovnc} \
                    --vnc 127.0.0.1:${toString config.PORTS.hermesVnc} \
                    --heartbeat 15'';
        Restart = "always";
        RestartSec = "5s";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };

    # Traefik tailnet router: https://hermes-desktop.hp (step-ca cert, fleet
    # DNS record, DNS + router auto-wired by MODULES.networking.traefik).
    # HTTP-leg auth is the tailnet itself (joplin.nix precedent); the real
    # gate is the VNC Challenge prompt noVNC raises on connect.
    MODULES.networking.traefik.services.hermes-desktop = "127.0.0.1:${toString config.PORTS.hermesNovnc}";

    # Raw VNC too (owner: "webvnc or openvnc"): native clients (RealVNC,
    # TigerVNC, the phone's VNC Viewer) get the same display over the tailnet
    # via tailscale serve's TCP forward - hp's tailscaled (host netns) dials
    # the loopback RFB port just like websockify does, x11vnc's -localhost
    # gate stays intact. The serve framework auto-emits BOTH sides of the
    # service graph (service-graph.nix derives `tailscale-serve-hermes-vnc`
    # edges, tailnet-source, from the serve map) so the nft filter and the
    # Suricata pass-list know this port without an entry here. Auth = the
    # same VncAuth password. hermes-desktop.hp:5901 (MagicDNS) is the address.
    MODULES.networking.tailscale.serve.hermes-vnc = {
      # Target spelling per the official example (`tailscale serve --tcp 2222
      # 22`): a bare LOCAL port; tailscaled dials 127.0.0.1:5901 itself, so
      # x11vnc's -localhost gate stays intact. httpPort/httpsPort unset = no
      # 443 bind (the ICS hermes-ics.nix 443 incident applies to HTTPS serve
      # only; TCP forwarders bind their explicit port and nothing else).
      target = toString config.PORTS.hermesVnc;
      tcpPorts = [config.PORTS.hermesVnc];
    };

    # --- the agent's browser ---------------------------------------------------------------
    # One HEADED Chromium (headed = default; --headless is NOT passed), shared
    # context across MCP re-attaches, profile under the state dir so logins
    # survive restarts, vision+pdf caps for the screenshot-click loop and
    # page-saves. Store paths inline (playwright-mcp.nix doctrine).
    systemd.services.hermes-playwright = {
      description = "Hermes Playwright MCP server (127.0.0.1:${toString config.PORTS.hermesPlaywright}, display :${toString cfg.display})";
      wantedBy = ["multi-user.target"];
      after = ["hermes-xvfb.service" "hermes-openbox.service"];
      requires = ["hermes-xvfb.service"];
      path = cfg.apps;
      environment = {
        DISPLAY = ":${toString cfg.display}";
        HOME = hermes.stateDir;
        XDG_RUNTIME_DIR = "/run/hermes-desktop";
        # The nixpkgs wrapper exports PLAYWRIGHT_MCP_ISOLATED=1 UNLESS
        # PLAYWRIGHT_MCP_USER_DATA_DIR is set (measured on the 0.0.83 wrapper:
        # `if [ -z "$PLAYWRIGHT_MCP_USER_DATA_DIR" ]; then export
        # PLAYWRIGHT_MCP_ISOLATED=1; fi`), and the server itself only reads
        # the profile location from the CLI flag - so BOTH spell the same
        # path: the env satisfies the wrapper's isolation check, the flag
        # (ExecStart below) tells playwright where the profile actually is,
        # under HERMES_HOME so it survives restarts inside the sandbox's rw
        # bind. The bundled PLAYWRIGHT_BROWSERS_PATH (store closure with
        # chromium-1248) stays exported for browser resolution.
        PLAYWRIGHT_MCP_USER_DATA_DIR = "${hermesHome}/desktop/playwright-profile";
      };
      serviceConfig =
        {
          User = hermes.user;
          Group = hermes.group;
          # No --executable-path: playwright's OWN bundled chromium (the
          # store's PLAYWRIGHT_BROWSERS_PATH closure) is the tested pairing
          # with this server version; system/unstable chromium would only
          # enter via an override when a site blocks HeadlessChrome UA
          # signatures, and the wrapper's PLAYWRIGHT_MCP_BROWSER=chromium
          # default already selects it.
          ExecStart = ''            ${cfg.playwrightPackage}/bin/playwright-mcp \
                        --user-data-dir ${hermesHome}/desktop/playwright-profile \
                        --caps vision,pdf \
                        --shared-browser-context \
                        --output-dir ${hermesHome}/desktop \
                        --host 127.0.0.1 --port ${toString config.PORTS.hermesPlaywright} \
                        ${lib.escapeShellArgs cfg.extraArgs}'';
          Restart = "always";
          RestartSec = "10s";
          ReadWritePaths = ["/run/hermes-desktop"];
        }
        # The fleet's Hermes sandbox verbatim (paseo-hermes precedent): the
        # browser's filesystem world equals the agent's, so screenshots saved
        # under HERMES_HOME are readable by the agent's terminal() and
        # nothing outside that sandbox leaks in.
        // sandbox
        // {
          # sandbox.BindPaths already carries stateDir (rw, so the profile
          # persists); the X socket + runtime dir join it. Three sandbox
          # fields widen for Chromium's real needs, each local-only and all
          # still inside every other sandbox wall:
          #  - AF_NETLINK: the network-change notifier (NETLINK_ROUTE).
          #  - ProcSubset=all + ProtectProc=default: Chromium reads /proc
          #    (memory maps, process stats); the sandbox default hides it.
          #  - @ptrace: the crashpad handler ptraces the browser processes.
          #    A headless desktop that OOM-killed one renderer and silently
          #    lost every tab is worse than one more local syscall group in
          #    a unit that already runs full Chrome.
          BindPaths =
            sandbox.BindPaths
            ++ [
              "/tmp/.X11-unix"
              "/run/hermes-desktop"
            ];
          RestrictAddressFamilies = sandbox.RestrictAddressFamilies ++ ["AF_NETLINK"];
          ProcSubset = "all";
          ProtectProc = "default";
          SystemCallFilter = sandbox.SystemCallFilter ++ ["@ptrace"];
        };
    };

    # --- the agent's side of the contract ---------------------------------------------------
    # DISPLAY through the FORK's `environment` option (attrsOf str, merged with
    # hermes-agent.nix's MATRIX_* block): activation writes it into
    # $HERMES_HOME/.env, which every hermes process loads - gateway, cron
    # workers, the dashboard's TUI sessions AND an `ssh hermes@hp` CLI - so one
    # line covers all of them (the systemd Environment leaf would only cover
    # the two units' own process env; .env is the fork's documented channel and
    # outranks stale shell exports by design).
    services.hermes-agent.environment.DISPLAY = ":${toString cfg.display}";

    # Attach order mirrors matrix-reader (wants/after, not requires: the
    # gateway must boot even if a desktop unit is wedged).
    systemd.services.hermes-agent = {
      wants = ["hermes-xvfb.service" "hermes-playwright.service"];
      after = ["hermes-xvfb.service" "hermes-playwright.service"];
    };
    systemd.services.hermes-backend = {
      wants = ["hermes-xvfb.service" "hermes-playwright.service"];
      after = ["hermes-xvfb.service" "hermes-playwright.service"];
    };

    # The X socket + runtime dir into BOTH units' sandboxes through the
    # fleet module's own feed option - hermes-agent.nix composes BindPaths
    # itself (notes share, apiKeyFile), and a second definition of the same
    # serviceConfig leaf would be the "attribute already defined" trap.
    MODULES.services.hermes-agent.extraSandboxBinds = [
      "/tmp/.X11-unix"
      "/run/hermes-desktop"
    ];

    MODULES.services.hermes-agent.extraPackages = cfg.apps;
    MODULES.services.hermes-agent.extraAllowedLoopbackPorts = [config.PORTS.hermesPlaywright];

    services.hermes-agent.mcpServers.playwright = {
      # /mcp = the streamable-HTTP endpoint (verified live on 0.0.83); the
      # legacy /sse exists too if Hermes' client ever needs it.
      url = "http://127.0.0.1:${toString config.PORTS.hermesPlaywright}/mcp";
      timeout = 300;
    };

    # The `desktop` skill (the agent's workstation manual) rides
    # agentDocuments' Hermes pack; that module's hermesDesktopSkill option
    # already defaults to this module's enable, so nothing to wire here.
  };
}
