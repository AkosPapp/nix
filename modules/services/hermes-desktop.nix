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
    # Obsidian for the notes vault (MODULES.services.hermes-agent.notes.shareDir
    # synced via syncthing): the human edits the same vault inside Hermes'
    # desktop that legion5 edits locally. Electron is proven ground in THIS
    # unit family: hermes-playwright runs a headed Chromium under the same
    # walls (CapabilityBoundingSet="", NoNewPrivileges, PrivateDevices,
    # llvmpipe GL), and Obsidian ships the same escape - its OWN main process
    # launches renderers with --no-sandbox --no-zygote (measured on legion5's
    # live 1.13.7 process tree 2026-11-26), so no setuid chrome-sandbox and no
    # user namespaces are needed; DISPLAY=:${toString cfg.display} is already
    # exported on the units and through the fork's .env.
    obsidian
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

  # --- the notes vault as Obsidian sees it (hermes-agent's notes.enable) --------------------
  # The doctrine check (hermes-agent.nix): the share root is 2755 and ONLY
  # <share>/hermes is 2775 - "outside hermes/ the agent can create or replace
  # nothing" - and the hermes uid has no write bit on the share root at all.
  # That is why the share-side .obsidian directory is NOT created by the
  # oneshot below (which runs as hermes, mkdir would EACCES): a tmpfiles rule
  # (root, pre-service) creates/re-asserts it at 2775, the one deliberate
  # widening - .obsidian is Obsidian's per-device state (excluded from sync
  # via the notes share's ignorePatterns), and 2775 grants exactly what the
  # app needs from THIS uid, the same scope <share>/hermes already carries
  # for the agent's own notes. Every other directory in the share stays 2755.
  #
  # The path the GUI registers is ${hermes.stateDir}/notes, NOT the raw
  # ${notesCfg.shareDir}: inside the agent units' sandbox the share arrives
  # as a BindPath at exactly that mount (hermes-agent's notes-bind), and
  # /var/lib is otherwise masked (TemporaryFileSystem=/var/lib:ro) or read-only
  # (ProtectSystem=strict on the plain desktop units), so the raw path is
  # either invisible or unwritable to anything in the desktop's namespaces.
  # This module binds the SAME `-<share>:<stateDir>/notes` mount into its own
  # long-running units below (openbox/term/playwright), so every namespace the
  # hermes uid runs an app in sees the vault at the same path - which is what
  # obsidian.json below must name or the vault picker would show "does not
  # exist". Writes stay mode-gated exactly like the agent's notes bind: the
  # GUI runs as the hermes uid, so it can write precisely what the agent can
  # (nothing wider: 2775 inside .obsidian, everything else 2755).
  notesCfg = config.MODULES.services.hermes-agent.notes;
  notesVaultMount = "${hermes.stateDir}/notes";
  # Same spec hermes-agent.nix composes for the two Hermes units ("-" prefix:
  # the folder may not exist yet on a fresh host; keep the unit up).
  notesVaultBind = ["-${notesCfg.shareDir}:${notesVaultMount}"];
  # Stable vault id: Obsidian's registry keys are arbitrary 16-hex strings;
  # derived from the mount path so re-deploys reuse one entry.
  notesVaultId = builtins.substring 0 16 (builtins.hashString "md5" notesVaultMount);

  # Idempotent vault registration, run as the hermes uid OUTSIDE the fleet
  # sandbox (its own serviceConfig below - the sandbox attrset masks /var/lib,
  # so it could not reach the raw share path the tmpfiles modes are set for):
  # seeds <share>/.obsidian/app.json and merges the vault into
  # ~/.config/obsidian/obsidian.json. jq merges rather than replaces: the app
  # itself may have added other vaults to that file by hand.
  notesVaultSetup = pkgs.writeShellScript "hermes-notes-vault" ''
    set -eu
    share="${notesCfg.shareDir}"
    vault="${notesVaultMount}"
    reg="${hermes.stateDir}/.config/obsidian/obsidian.json"
    JQ=${pkgs.jq}/bin/jq
    CORE=${pkgs.coreutils}/bin

    # <share>/.obsidian itself is created/re-asserted by the tmpfiles rules
    # ABOVE, not here: the doctrine's 2755 share root gives the hermes uid no
    # create bit ("outside hermes/ the agent can create or replace nothing" -
    # measured hp 2026-11-26: drwxr-sr-x syncthing:hermes), so a User=hermes
    # mkdir is EACCES by design. Seed app.json when present; only loudly
    # complain when the whole dir is missing (fresh host: syncthing hasn't
    # landed the folder yet - the next switch/sysinit re-run retries).
    if [ -d "$share/.obsidian" ]; then
      if [ ! -e "$share/.obsidian/app.json" ]; then
        printf '{}\n' > "$share/.obsidian/app.json"
        "$CORE/chmod" 0664 "$share/.obsidian/app.json"
      fi
    else
      echo "hermes-notes-vault: $share/.obsidian missing (share not materialised?); tmpfiles + next activation will create it" >&2
    fi

    "$CORE/mkdir" -p "${hermes.stateDir}/.config/obsidian"
    tmp="$("$CORE/mktemp")"
    if [ -s "$reg" ]; then
      "$CORE/cat" "$reg" > "$tmp"
    else
      printf '{"vaults":{}}\n' > "$tmp"
    fi
    # MERGE, never replace: the app itself may have registered other vaults
    # by hand from the GUI (obsidian.json is its vault-switcher list).
    $JQ -c --arg id "${notesVaultId}" --arg path "$vault" \
      '.vaults[$id] = {path: $path, ts: 1}' "$tmp" > "$tmp.merged"
    "$CORE/cat" "$tmp.merged" > "$reg"
    "$CORE/rm" -f "$tmp" "$tmp.merged"
  '';
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

    systemd.tmpfiles.rules =
      [
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
      ]
      ++ lib.optionals notesCfg.enable [
        # Obsidian's per-user registry lives in $HOME/.config/obsidian (HOME IS
        # stateDir on every desktop unit), 0700 like the hermes home around it.
        "d ${hermes.stateDir}/.config/obsidian 0700 ${hermes.user} ${hermes.group} - -"
        # The vault's per-device .obsidian INSIDE the share. tmpfiles (root) is
        # the only actor that can create it: the doctrine leaves the share root
        # 2755 with no hermes write bit (hp 2026-11-26: syncthing:hermes
        # drwxr-sr-x), so a hermes-uid mkdir - the obvious oneshot move - is
        # EACCES by design. 2775 = the ONE deliberate widening beyond
        # <share>/hermes, scoped exactly to Obsidian's own state dir (its churn
        # is excluded from sync by the share's ignorePatterns, so no other
        # device ever sees it); every other directory keeps 2755, and the
        # setgid bit + app.json 0664 let the hermes uid write in place. The `f`
        # line seeds app.json with {} once and never touches existing content
        # (tmpfiles writes the argument only at creation).
        # Same share-root line hermes-agent.nix emits: tmpfiles runs one merged,
        # ordered conf and a plain `d` silently skips when the parent is absent,
        # so re-asserting it HERE (idempotent: same mode/owner as the agent's
        # rule) makes the .obsidian line immune to inter-module ordering.
        "d ${notesCfg.shareDir} 2755 ${notesCfg.shareOwner} ${hermes.group} - -"
        "d ${notesCfg.shareDir}/.obsidian 2775 ${notesCfg.shareOwner} ${hermes.group} - -"
        "f ${notesCfg.shareDir}/.obsidian/app.json 0664 ${notesCfg.shareOwner} ${hermes.group} - {}"
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
        # Electron apps launched from anywhere on this desktop (WM menu, the
        # term below, pcmanfm) inherit it: the SUID sandbox helper cannot work
        # against the read-only store (chrome-sandbox can never be root:4755
        # here, and NoNewPrivileges/RestrictNamespaces close both fallbacks),
        # so without this Electron ABORTS ("The SUID sandbox helper binary was
        # found, but is not configured correctly" - measured on hp 2026-11-26
        # running obsidian on :${toString cfg.display}). Disabling it is the
        # documented opt-out and the same trust model the module already
        # applies to Chromium (playwright launches with chromiumSandbox=false:
        # only trusted local apps run here).
        ELECTRON_DISABLE_SANDBOX = "1";
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
        # Notes-vault bind, same spec hermes-agent composes for its own units:
        # every namespace the hermes uid runs desktop apps in must see the
        # vault at the SAME mount path the registry names (see notesVaultBind;
        # writes stay mode-gated - this grants nothing the agent's bind
        # doesn't already carry for this uid).
        BindPaths = ["/tmp/.X11-unix"] ++ lib.optionals notesCfg.enable notesVaultBind;
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
        # Same Electron story as hermes-openbox above: this xterm is where
        # the human (and the agent's terminal()) launch apps, and their
        # children inherit the var.
        ELECTRON_DISABLE_SANDBOX = "1";
      };
      serviceConfig = {
        User = hermes.user;
        Group = hermes.group;
        ExecStart = "${pkgs.xterm}/bin/xterm -geometry 110x32+20+20 -hold";
        Restart = "on-failure";
        RestartSec = "10s";
        PrivateTmp = true;
        # The human's (and the agent's) shell: `obsidian` launched here edits
        # the vault, so it gets the same notes bind as openbox/playwright.
        BindPaths =
          ["/tmp/.X11-unix" "/run/hermes-desktop"]
          ++ lib.optionals notesCfg.enable notesVaultBind;
        # stateDir joins the rw set for the Obsidian GUI launched from this
        # shell: Electron's user-data dir is ~/.config/obsidian (registry,
        # IndexedDB, GPU cache), and ProtectSystem=strict alone would make
        # every write there EROFS - same opening hermes-openbox already
        # carries for the same reason (its ~/.cache lesson above).
        ReadWritePaths = ["/run/hermes-desktop" hermes.stateDir];
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

    # Registers the notes vault with Obsidian for the hermes uid: seeds
    # <share>/.obsidian/app.json and merges the vault (path = the sandbox-
    # visible mount, see notesVaultMount) into ~/.config/obsidian/obsidian.json.
    # Runs OUTSIDE the fleet sandbox ON PURPOSE: it touches the RAW share path
    # (/var/lib/notes), which the sandbox masks via TemporaryFileSystem=
    # /var/lib:ro; the hardening below is the module's own light shape, like
    # hermes-novnc's. Re-runs on every switch via sysinit-reactivation: the
    # 26.05 switcher's "start new units" pass skips fresh oneshots after a
    # deploy (the herdr.nix/datalab-harness.nix lesson), and re-running on
    # every activation is the correct semantic - the script is idempotent.
    # Ordering is wants/after on hermes-openbox, never requires: a vault that
    # cannot be registered (share not synced yet) must not take the desktop
    # down, and Obsidian reads obsidian.json at LAUNCH, so the merge only has
    # to precede a human/agent actually opening the app.
    systemd.services.hermes-notes-vault = mkIf notesCfg.enable {
      description = "Seed the Obsidian vault state in the notes share and register it for ${hermes.user}";
      # multi-user = boot (sysinit-reactivation.target is only RESTARTED by
      # the switcher, never pulled in at boot - the datalab-harness.nix pair
      # this copies); sysinit-reactivation = every switch.
      wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
      after = ["systemd-tmpfiles-setup.service" "hermes-openbox.service"];
      wants = ["hermes-openbox.service"];
      serviceConfig = {
        Type = "oneshot";
        User = hermes.user;
        Group = hermes.group;
        ExecStart = "${notesVaultSetup}";
        # stateDir is the hermes uid's own home (the tmpfiles obsidian dir
        # lives under it); /nix/store is read-only by default and reachable
        # (no TemporaryFileSystem here). The share paths it writes are
        # mode-gated (2775 .obsidian); ProtectSystem=strict keeps everything
        # else read-only, so this unit can change exactly the two files the
        # script names.
        ReadWritePaths = [hermes.stateDir];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        # The share-side file must land group-writable/0664 per the doctrine
        # (hermes writes, syncthing-owner reads); the fleet Hermes units'
        # UMask=0077 would make it 0600 and invisible to `other`.
        UMask = "0022";
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
            ]
            # The notes vault for Chromium's world too (same spec as the
            # agent's bind): playwright's file tooling and the
            # browser-side "save into vault" flows need the share visible at
            # the mount path the registry names - under the sandbox,
            # TemporaryFileSystem=/var/lib:ro masks the raw path.
            ++ lib.optionals notesCfg.enable notesVaultBind;
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
    # And the Electron opt-out on the same channel, so an `obsidian` the
    # agent starts through its own terminal() inherits it too (see the
    # hermes-openbox unit for why Electron cannot keep its sandbox here).
    services.hermes-agent.environment.ELECTRON_DISABLE_SANDBOX = "1";

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
