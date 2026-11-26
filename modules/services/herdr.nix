# herdr: "the runtime your coding agents live on" (herdr.dev). Three distinct programs share
# the name, and this module installs them on every machine that enables it - they do NOT
# share state or sessions, so "both the CLI and the app" means more than one package:
#
#   herdr          the TUI + its own background server  - bin/herdr
#   herdr-core     the app's terminal backend           - bin/hc, bin/herdr-core
#   herdr-desktop  the GUI "Herdr" app                  - bin/herdr-app + .desktop + icon
#
# All three come from nixpkgs (pkgs/by-name/he/herdr*), so there is nothing to maintain here:
# versions move when the nixpkgs-unstable pin moves. Pin state measured 2026-11-08: this
# flake's nixpkgs-unstable rev 1c89083e451e has only the TUI (0.9.5); herdr-core 0.1.15 and
# herdr-desktop 0.1.10 exist on the branch tip but not at our rev, and none of the three are
# in nixos-26.05, which is what the hosts otherwise run. One 'nix flake update
# nixpkgs-unstable' brings all three in - see the assertions for what a switch says when the
# pin has not moved yet.
#
# herdr-core owns its core/holder processes as transient systemd user services;
# this module never replaces them with a competing system unit. Both products
# start their own server on first use and survive the spawning logout. Upstream
# recommends non-root cores; the existing hp/root deployment is an explicit hub
# exception, not a claim that hc avoids running its backend as root.
#
# What we DO provide is the scaffolding a user manager cannot make for itself: linger (so
# /run/user/<uid> exists at boot - the directory the core puts its sockets in) and the
# private config/state directories. Look at what came up with `systemctl --user`. The
# app's agent MENU is declarative too (MODULES.services.herdr.agents ->
# ~/.config/herdr-app/programs.json, merged at activation): upstream's built-in
# table (verified against v0.1.10's defaults/programs.json 2026-11-09) lacks the
# fleet's omp/cline/kilo, so without this the GUI never offers them and their
# panes render as generic "Program" tiles (legion5 report 2026-11-09).
#
# Multiple machines: enable the module per host and list the users who get state
# (including hp/root as the hub operator). Machines join each other over SSH:
# `herdr machine add <host>` / `hc machine add <host>`
# - which is exactly why the binaries are installed on the headless servers too: an
# agent in an hp terminal keeps running there after you disconnect.
#
# The TUI's machine list is DECLARATIVE (MODULES.services.herdr.machines, 2026-11-09): the
# fleet's herdr-enabled hosts appear automatically (derived from nixosConfigurations exactly
# like service-graph's peer tables - hostIP + MODULES.networking.sshClient.hostKeys), so every
# herdr user on every host sees the same catalog with the same deterministic profile ids and
# nobody ever types `machine add` for a fleet box. That is what makes the hp-as-hub phone
# story work: the phone (Termius) connects to ONE host (hp), and hp's herdr client
# sidebar already carries legion5/akos01/whatever-is-enabled - adding a host (tailnet or
# not: declare it under `machines` with hostname+knownHosts like r4uai00 will be) is one
# deploy, not N manual `machine add`s per user per host. Non-flake hosts are plain
# declarations; their public host keys are restated as known_hosts lines because nothing
# in the flake knows them.
#
# The CORE catalog is runtime data, but its REMOTE core IDs are portable. Opt-in
# coreRegistry bridges only <state>/herdr-core/<session>/machines.json through a
# dedicated, file-filtered Syncthing folder. Never share core.json (local identity),
# sockets, peers, terminals or screens. Each participant writes its own operation
# file; the bridge merges records/tombstones and restarts an existing core with
# hc's holder-preserving restart because v0.1.15 does not hot-reload machines.json.
#
# Hub identity: on a host with MODULES.services.herdr.sshKeySecret set (hp), the generated
# `Host herdr-*` blocks pin that sops key (IdentitiesOnly + BatchMode) so hub ssh never
# depends on an agent or on root's login keys; the matching public half sits in
# profiles/global.nix root authorizedKeys (and users/akos.nix for the laptop).
# Root as hub operator is an accepted fleet tradeoff; hc uses that user's core,
# so the root-core upstream recommendation is not satisfied on the hub.
#
# No firewall port and no SERVICE_GRAPH edge: every socket here is a UNIX socket under
# /run/user/<uid>, and the cross-machine path is plain user-initiated SSH to sshd, which is
# already open on every host via MODULES.networking.sshd (the ssh-tailnet edge already covers
# :22 in both directions - hp's nightly znapzend push dials it the same way) and is not a
# service-uid flow the jail or the Suricata tap sees.
#
# Why install* default to "does the pin have it" rather than true: with the pin still at
# 1c89083e451e a flat true would make every host that merely wants the TUI fail its
# assertions. Packages resolve through `or null` for the same reason - a stale pin should
# name the command that fixes it, not die as an "undefined attribute path" mid-switch.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  # specialArgs (flake.nix): the fleet's own configs, read for the derived machine catalog
  # exactly like modules/security/service-graph.nix reads them for its edge table.
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption literalExpression types;

  cfg = config.MODULES.services.herdr;

  # The three packages. The fleet builds against pkgs-unstable (the pin modules/services/
  # coroot.nix already uses for exactly this reason: herdr, its core and its desktop app are
  # a Rust/zig trio that only ever lands in nixpkgs -stable a cycle late), so that is where
  # they come from. `or null` rather than a direct select so a stale pin says which package
  # is missing (see the assertions) instead of taking down every host that enables this
  # module with "the attribute 'herdr-desktop' does not exist".
  herdrPkg = pkgs-unstable.herdr or null;
  corePkg = pkgs-unstable.herdr-core or null;
  # The desktop app depends on herdr-core by attribute name and pulls in vulkan-loader,
  # wayland and the font stack; it only builds for x86_64-linux / aarch64-linux.
  # buildInputs fix (measured 2026-11-09 at nixpkgs-unstable f4a03c008967): the zstd-sys
  # crate in its vendor tree needs pkg-config `libzstd`, which the nixpkgs expression does
  # not supply, so the crate build dies with "the system library `libzstd` required by
  # crate `zstd-sys` was not found" (cache.nixos.org has no herdr-desktop build at this
  # rev either, so nobody upstream hit it yet). overrideAttrs (not //) so the drv actually
  # rebuilds and the package's own buildInputs survive. Drop the override once the pin
  # carries a rev whose herdr-desktop expression lists zstd.
  appPkg =
    if pkgs-unstable ? herdr-desktop
    then
      pkgs-unstable.herdr-desktop.overrideAttrs (final: prev: {
        buildInputs = (prev.buildInputs or []) ++ [pkgs-unstable.zstd];
        # Sidebar-name fix (measured on legion5 2026-11-12, live-patched into the running
        # app's mod dir first): the bundled agents mod shows an agent's live chat title ONLY
        # when tab.name equals the programs.json display name - and OUR entry for omp IS
        # "oh-my-pi" - so every tab herdr auto-numbered (splits, adopted terminals, "+")
        # falls back to that display name and the chat title is never seen. Upstream fixed
        # exactly this in herdr-app v0.1.12 (diffed the raw agents/main.js v0.1.10..v0.1.12:
        # `tab.name === prog` gained `|| !tab.named`); the `named` flag is already on tabs in
        # the pinned v0.1.10's mods API (model.rs), so the one-line backport below is
        # byte-identical to the upstream fix. The mod JS is embedded into the binary at
        # build time (build.rs reads defaults/mods/; the shipped string was grepped out of
        # the built binary), and the app re-syncs its per-user mods dir when the shipped
        # fingerprint changes, so a switch heals existing homes without manual edits.
        # Remove once the pin carries herdr-desktop >= 0.1.12.
        postPatch =
          (prev.postPatch or "")
          + lib.optionalString (lib.versionOlder prev.version "0.1.12") ''
            substituteInPlace defaults/mods/agents/main.js \
              --replace-fail 'tab.name === prog && telling' '(tab.name === prog || !tab.named) && telling'
          '';
      })
    else null;

  # Users whose herdr state we lay out. The TUI and the app are two different programs, so
  # each user picks them independently (userDirs / userConfigSeeds branch on cli.enable and
  # app.enable); a user with both gets both, and the two servers stay separate - agents
  # started in the TUI do not appear in the app and vice versa, upstream's own FAQ.
  # Enabling either implies linger, which is why the linger map keys off this, not the
  # narrower sets.
  managedUsers = lib.filterAttrs (_: u: u.enable) cfg.users;

  registryEnabled = cfg.coreRegistry.user != null;
  registryParticipants =
    lib.filterAttrs (
      _: hc:
        (hc.config.MODULES.services.herdr.enable or false)
        && (hc.config.MODULES.services.herdr.coreRegistry.user or null) != null
    )
    nixosConfigurations;
  registryShare = "/var/lib/herdr-machine-registry";
  registryLedger = "/var/lib/herdr-machine-registry-private";
  registryAccount = config.users.users.${cfg.coreRegistry.user} or null;
  registryState = "${registryAccount.home}/.local/state/herdr-core/${cfg.coreRegistry.session}";
  registrySyncthingUser = config.services.syncthing.user;
  registrySettings = pkgs.writeText "herdr-registry-settings.json" (builtins.toJSON {
    node = configName;
    user = cfg.coreRegistry.user;
    session = cfg.coreRegistry.session;
    version = corePkg.version;
    selfTarget = machineAlias configName;
    state = registryState;
    share = registryShare;
    ledger = registryLedger;
    syncthingUser = registrySyncthingUser;
    participants = builtins.attrNames registryParticipants;
    hc = "${corePkg}/bin/hc";
    runuser = "${pkgs.util-linux}/bin/runuser";
    aliases = builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (
        n: m:
          map (target: lib.nameValuePair target (machineAlias n))
          ([n (machineAlias n)] ++ lib.optional (m.hostname != null) m.hostname)
      )
      resolvedMachines));
  });

  # Participant peers reuse declared public SSH routing/pins, NEVER private keys.
  registryMachineFacts = lib.foldl' (
    acc: hc:
      lib.recursiveUpdate acc (lib.filterAttrs (n: _: !builtins.hasAttr n nixosConfigurations)
        hc.config.MODULES.services.herdr.machines)
  ) {} (builtins.attrValues (lib.filterAttrs (n: _: n != configName) registryParticipants));
  declaredMachines =
    lib.recursiveUpdate
    (lib.optionalAttrs registryEnabled registryMachineFacts)
    cfg.machines;

  # Directory scaffolding for one user. Both programs create their own dirs on first run,
  # so this is deliberately only about the two things that go wrong without it: the
  # permissions, and the directories existing before a service (or the GUI) first touches
  # them as a different uid. herdr-core documents that it creates its state and socket dirs
  # 0700 and "does not repair permissions on directories that already exist", so we match
  # 0700 here and never create anything it will later want to make itself wider.
  #
  # 0700 matters more than usual for these specific paths: the core's state dir holds saved
  # terminal screens and scrollback, which is where an agent's API keys end up after they
  # scroll past, and the TUI writes its own logs under its config dir.
  #
  # Parents are declared, not assumed: modules/services/paseo-machine.nix measured that
  # tmpfiles creates undeclared intermediates root-owned, which then breaks whatever runs as
  # the user. A fresh account has ~/.config but no ~/.local/state yet, so both legs are
  # listed. The socket itself is NOT pre-created: herdr-core owns
  # $XDG_RUNTIME_DIR/herdr-core/ and a stale socket file we made would only confuse it.
  userDirs = name: let
    # `or null` rather than a bare select: config.assertions below is what should report a
    # name with no account, and an obscure "attribute herdr-x is missing" raised from deep
    # inside the tmpfiles list would bury that message (same reason paseo-machine.nix asserts
    # before it reads config.users.users).
    ua = config.users.users.${name} or null;
    g = ua.group;
    # 0700 on the XDG parents too, which is what modules/services/kilo.nix already declares
    # for $HOME/.config on this fleet - same value, so the two modules agree rather than
    # fighting over one path's mode.
    dir = p: "d ${p} 0700 ${name} ${g} -";
  in
    if ua == null
    then []
    else
      (lib.optionals cfg.users.${name}.cli.enable [
        (dir "${ua.home}/.config")
        # The TUI reads config.toml here and writes herdr.log / herdr-server.log beside it.
        (dir "${ua.home}/.config/herdr")
        # Its server's socket + per-session dirs live under the CONFIG dir (session.rs
        # data_dir_for: ~/.config/herdr/[sessions/<name>]/herdr.sock - verified against
        # v0.9.x 2026-11-09), so this 0700 covers those too.
        (dir "${ua.home}/.local")
        (dir "${ua.home}/.local/state")
        # Its server's session state; separate from the core's, on purpose (see the header).
        (dir "${ua.home}/.local/state/herdr")
        # The CLIENT's machine catalog (endpoints.json) goes here; the merge unit expects
        # it (0700, same reason: agent scrollback and hub ssh targets are on disk).
        (dir "${ua.home}/.local/state/herdr/client")
      ])
      ++ (lib.optionals cfg.users.${name}.app.enable (
        (lib.optionals (!cfg.users.${name}.cli.enable) [
          (dir "${ua.home}/.config")
          (dir "${ua.home}/.local")
          (dir "${ua.home}/.local/state")
        ])
        ++ [
          # herdr-core: config.toml + a templates/ dir beside it.
          (dir "${ua.home}/.config/herdr-core")
          # Per-session terminal records, saved screens, machine list, core.log, holder.log.
          (dir "${ua.home}/.local/state/herdr-core")
          # The app's own, agent-editable surface: settings.json, keys.json, layouts/, mods/,
          # themes/ plus the AGENTS.md that explains them to an agent.
          (dir "${ua.home}/.config/herdr-app")
        ]
      ));

  # Minimal TOML emitter. Both herdr config files are TOML-only and nixpkgs has no TOML
  # generator: verified 2026-11-09 against both pins, `lib.generators ? toTOML` evaluates to
  # false and selecting it errors "attribute 'toTOML' missing ... Did you mean toYAML?" at
  # nixpkgs' lib/default.nix:83. So the module carries its own rather than writing JSON,
  # which neither program can parse.
  #
  # Verified round-tripping through tomllib 2026-11-09: nested tables, lists, quoted
  # non-bare keys ("dotted key" = 5), and the scalar-before-table ordering below all parse
  # back to the exact input attrset.
  #
  # Covers what the options here can produce: bools, ints, floats, strings, lists of those,
  # and tables nested to any depth. Anything else throws at eval time rather than writing a
  # file herdr would silently fall back past with a startup warning.
  toToml = let
    # Bare key where TOML allows one, quoted where it does not.
    key = k:
      if builtins.match "[A-Za-z0-9_-]+" k != null
      then k
      else builtins.toJSON k;
    atom = v:
      if builtins.isBool v
      then
        (
          if v
          then "true"
          else "false"
        )
      else if builtins.isInt v || builtins.isFloat v
      then toString v
      else if builtins.isString v
      then builtins.toJSON v
      else if builtins.isList v
      then "[" + lib.concatMapStringsSep ", " atom v + "]"
      else throw "MODULES.services.herdr.toToml: ${builtins.toJSON v} is neither a TOML scalar nor a list of scalars";
    # Scalars always precede sub-tables, at every level. TOML has no way to say "back to the
    # top level" once a [table] header has been written, so { session = {...}; foo = 1; }
    # must emit foo BEFORE [session] or the reader takes foo as a key of session. Herdr
    # configs hit this as soon as someone sets both cli.settings ([session]) and a top-level
    # extraConfig key like onboarding, so the order is load-bearing, not cosmetic.
    table = path: attrs: let
      scalars = lib.filterAttrs (_: v: !builtins.isAttrs v) attrs;
      subTables = lib.filterAttrs (_: v: builtins.isAttrs v) attrs;
      header =
        if path == []
        then ""
        else "[${lib.concatStringsSep "." (map key path)}]\n";
      body = lib.concatStrings (lib.mapAttrsToList (k: v: "${key k} = ${atom v}\n") scalars);
      children = lib.concatStrings (
        lib.mapAttrsToList (k: v: lib.optionalString (body != "") "\n" + table (path ++ [k]) v)
        subTables
      );
    in
      header + body + children;
  in
    table [];

  # The TUI's config.toml, written only for users who set something. herdr documents every
  # key and tolerates a partial file (herdr --default-config prints the whole default set),
  # so omitting a block leaves that default in place.
  configToml = uCfg:
    toToml (
      (lib.optionalAttrs (uCfg.cli.headlessCols != null) {server.headless_cols = uCfg.cli.headlessCols;})
      // (lib.optionalAttrs (uCfg.cli.headlessRows != null) {server.headless_rows = uCfg.cli.headlessRows;})
      // (lib.optionalAttrs (uCfg.cli.settings != {}) {session = uCfg.cli.settings;})
      // uCfg.cli.extraConfig
    );

  # Per-user submodule. Inline rather than a file under modules/services/herdr/, because the
  # flake's module_files globs every *.nix under modules/ recursively into every host's
  # module list - a submodule saved as its own file there would also be imported as a
  # top-level module and define stray top-level options. Same reason opencode.nix keeps its
  # providerSubmodule inline.
  userSubmodule = {
    options = {
      enable = mkEnableOption "herdr state for this user (also turns on their linger)";

      cli = {
        enable = mkEnableOption ''
          the herdr TUI for this user: creates ~/.config/herdr and ~/.local/state/herdr.
          The TUI starts its own server; nothing here starts it for it - EXCEPT
          together with cli.service, which keeps a unit running for accounts that
          can't start one any other way (see its docs).
        '';
        service = mkEnableOption ''
          a system unit (herdr-server-<user>, see the systemd.services block in this
          module) that keeps THIS USER's herdr TUI server up at boot and on every
          switch, stopping it with `herdr server stop` on unit stop.

          The deliberate exception to "nothing here starts a server": it exists for
          accounts that must NEVER get a systemd user manager (linger off), where
          neither path to a persistent server works - herdr's own remote bootstrap
          spawns no remote server over a plain ssh (measured on hp 2026-11-10
          against the linger-less hermes account: the client authenticated, the
          bridge ran, `ps` during the attach showed no server process ever), and
          enabling lingering for the account instead would move the Hermes gateway's
          cron workers into user-scope units outside the unit sandbox (the doctrine
          documented in modules/services/hermes-agent.nix). Panes of a unit-started
          server inherit the UNIT's environment, so pair this with
          cli.extraConfig.terminal.shell_mode = "login" where the pane shell needs
          the user's profile PATH.
        '';
        headlessCols = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          example = 220;
          description = ''
            Virtual terminal width when no client is attached (server.headless_cols); null
            keeps herdr's default of 120. Worth raising on a headless server the user only
            reaches over SSH: agents that measure the terminal width (pi, opencode) lay out
            their output for the headless size while detached, so 120 means reflowed or
            truncated output for a 200-column terminal.
          '';
        };
        headlessRows = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          example = 50;
          description = "Virtual terminal height when detached (server.headless_rows); null keeps 40.";
        };
        settings = mkOption {
          type = types.attrsOf types.anything;
          default = {};
          example = literalExpression ''
            { resume_agents_on_restore = true; startup_per_agent_delay_ms = 100; }
          '';
          description = ''
            Keys for the TUI's [session] table - what it does with agent panes when the
            server comes back. resume_agents_on_restore (upstream default true) re-enters
            supported agents' own conversation sessions after a server restart;
            startup_per_agent_delay_ms staggers those restores so several agents do not hit
            the gateway at the same instant. Anything in the reference's [session] block
            goes here.
          '';
        };
        extraConfig = mkOption {
          type = types.attrsOf types.anything;
          default = {};
          example = literalExpression ''
            { theme.name = "gruvbox"; onboarding = false; }
          '';
          description = ''
            Everything else for the TUI's config.toml. Nested attrs become TOML tables;
            keys the named options above already emit are overridden by what goes here.
            herdr --default-config prints the full default file, and
            herdr.dev/docs/config-reference lists every key. Values must be scalars,
            lists of scalars, or tables - anything else throws at eval time.
          '';
        };
      };

      app = {
        enable = mkEnableOption ''
          the Herdr desktop app's state for this user: creates ~/.config/herdr-app (its
          agent-editable settings/keys/layouts/mods/themes), plus the ~/.config/herdr-core
          and ~/.local/state/herdr-core the app's terminals actually live in.
        '';
        coreConfig = mkOption {
          type = types.attrsOf types.anything;
          default = {};
          description = ''
            Keys for herdr-core's config.toml - the backend the app attaches to, so this is
            where the terminal behaviour that is NOT presentation belongs: shell = ["nu"] to
            pick the shell new terminals get, notes = false to stop hc typing status notes
            into parent agents on its own, wait_timeout, the socket override. Pane and
            template defaults are the server's; themes and layouts are the app's local
            files. herdr.dev/docs/config-reference covers the core's keys too.
          '';
        };
      };
    };
  };

  # The app's program table (herdr.dev: the GUI's agent menu and pane icons come
  # from defaults/programs.json built into the binary, with the user's
  # ~/.config/herdr-app/programs.json merged on top entry-by-entry - verified
  # against herdr-app v0.1.10's src/programs.rs load(): `table.programs
  # .entry(key).or_default().over(entry)`, and window.rs re-runs load() whenever
  # that file changes, so an activation-time write hot-reloads a running app).
  #
  # Upstream's built-in table knows claude, codex, pi, opencode, amp and friends
  # but NOT the fleet's other harnesses (omp, cline, kilo have no entry, so the
  # menu never offers them and their panes fall back to the generic hash-colored
  # "Program" tile). cfg.agents renders the override file so the NixOS-declared
  # harness set is the declared herdr set. Entry schema (src/programs.rs Entry):
  # name/icon/tint/tile/color plus `match` (extra process names, serialized as
  # "match") and `run` (the command a menu entry starts; an entry WITHOUT run is
  # display-only). The app lists only entries whose run command `command -v`
  # finds, so declaring the full harness set is harmless on a host missing one.
  # `match` matters for omp: its argv0 is `omp`, but the pane-detection `app`
  # name the agent reports must alias too if omp ever reports one (pi reports
  # "pi" as "claude-code" does).
  agentEntrySubmodule = {name, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        description = "Display name in the app's menus and pane headers.";
      };

      run = mkOption {
        type = types.listOf types.str;
        default = [name];
        example = ["omp"];
        description = "argv that starts the agent from the app's menus ([] makes the entry display-only).";
      };

      match = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra process/`app` names that resolve to this entry (the table key itself always does).";
      };

      icon = mkOption {
        type = types.nullOr types.str;
        default = "icons/agent.svg";
        example = "icons/agent.svg";
        description = ''
          Icon path relative to ~/.config/herdr-app (the app copies its shipped
          icons there, so "icons/agent.svg" reuses the built-in bot glyph; a
          custom SVG must be placed beside it by the host). The mods render
          nothing at all for a null icon, hence the shipped-glyph default -
          upstream has no icon for omp/cline/kilo.
        '';
      };

      tint = mkOption {
        type = types.bool;
        default = true;
        description = "Draw the icon as a one-color glyph (true) or as a picture (false).";
      };

      tile = mkOption {
        type = types.nullOr types.str;
        default = "#1c1d21";
        description = "Tile background color (upstream's harness default).";
      };

      color = mkOption {
        type = types.nullOr types.str;
        default = "#ffffff";
        description = "Foreground/glyph color of the tile.";
      };
    };
  };

  # One declared TUI-machine ("herdr machine add" equivalent). Every field defaults to
  # "inherit the fleet fact / upstream default" so a tailnet host that merely enables this
  # module needs ZERO machines entries (see fleetMachines); an explicit row is only for
  # overriding one field (`machines.hp.user = "herdr"`) or for hosts the flake cannot see
  # (off-tailnet boxes like r4uai00: hostname + knownHosts are the minimum there).
  # Field set = the SavedSshEndpoint schema (verified against v0.9.x src/client/endpoint/
  # catalog.rs 2026-11-09): the catalog file has deny_unknown_fields, so exactly
  # id/label/target/session/enabled reach disk and NOTHING else may.
  machineEntrySubmodule = {name, ...}: {
    options = {
      label = mkOption {
        type = types.str;
        default = name;
        description = "Sidebar name (herdr caps labels at 128 bytes, no control chars).";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "herdr";
        description = "SSH user for the hub -> machine hop; null resolves to root (the fleet's admin identity everywhere, and the only account on hp/akos01).";
      };

      hostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.210.0.10";
        description = ''
          Address the alias resolves to (ssh config's HostName). Null = this host's
          MODULES.networking.tailscale.hostIP when the flake can see it; REQUIRED for
          off-flake hosts.
        '';
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "SSH port; null keeps ssh's default (22).";
      };

      session = mkOption {
        type = types.str;
        default = "default";
        description = "The remote herdr SESSION (server) to attach; [A-Za-z0-9._-], <= 64 bytes (upstream validate_name). One profile targets one session.";
      };

      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "false keeps the row but hides it from every catalog (herdr's own machine disable).";
      };

      knownHosts = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          known_hosts lines for this machine's host key(s), keyed by ANY address - they
          are re-keyed to the herdr-<name> alias at render. [] = the flake host's
          MODULES.networking.sshClient.hostKeys; off-flake hosts MUST set them (public
          material; ssh-keyscan <addr> is the source, same 2026-11-03 cross-check
          doctrine as tuvpn pins). An entry with no resolvable key fails the assertion -
          BatchMode hub ssh must die at host verification, never TOFU silently.
        '';
      };
    };
  };

  # The flake's own herdr hosts minus this one, as catalog rows (the cross-host-facts-
  # through-specialArgs pattern of service-graph.nix; microVM guests deliberately see
  # nixosConfigurations = {} and therefore derive nothing, which is correct - they are not
  # hub targets until someone declares them under `machines` with a literal address).
  fleetMachines =
    lib.mapAttrs' (
      h: hc:
        lib.nameValuePair h {
          hostname = hc.config.MODULES.networking.tailscale.hostIP or null;
          knownHosts = hc.config.MODULES.networking.sshClient.hostKeys or [];
        }
    ) (
      lib.filterAttrs (
        h: hc:
          h != configName && hc.config.MODULES.services.herdr.enable or false && hc.config.MODULES.services.herdr.installCli or true
      )
      nixosConfigurations
    );

  # Field-wise resolution (the attrsOf-trap doctrine): a host's partial override may set
  # ONE field; the fleet fact fills every null/[] the override left.
  resolvedMachines = let
    # The union: fleet-derived rows, declared rows, and names declared for hosts the
    # flake cannot see (off-tailnet). A declared row for a FLEET host overrides the
    # derived row field by field; absent fields fall through to the fleet facts.
    names = lib.unique (builtins.attrNames fleetMachines ++ builtins.attrNames declaredMachines);
    declaredOr = n:
      if declaredMachines ? ${n}
      then declaredMachines.${n}
      # A derived-only row: the submodule defaults, written out (the trap this whole
      # attrset design exists to dodge - we must NOT read the merged option's default).
      else {
        label = n;
        session = "default";
        enabled = true;
        hostname = null;
        user = null;
        port = null;
        knownHosts = [];
      };
  in
    lib.genAttrs names (
      n: let
        e = declaredOr n;
        a = fleetMachines.${n} or {};
        # NOT `e.hostname or a.hostname`: submodule attrs EXIST with their default (null),
        # and `or` only guards missing attributes - a present null would flow through.
        orFleet = v: fv:
          if v != null
          then v
          else fv;
      in {
        inherit (e) label session enabled;
        user =
          if e.user != null
          then e.user
          else if builtins.hasAttr n registryParticipants
          then nixosConfigurations.${n}.config.MODULES.services.herdr.coreRegistry.user
          else "root";
        hostname = orFleet e.hostname (a.hostname or null);
        port = e.port;
        knownHosts =
          if e.knownHosts != []
          then e.knownHosts
          else a.knownHosts or [];
      }
    );

  # The alias ssh dials, and the deterministic 32-lowercase-hex profile id. The id MUST be
  # identical on every host or the same machine would appear twice per user (once declared,
  # once hand-added): hashing the name is what makes hp's and legion5's catalogs agree
  # byte-for-byte. 64 profiles is herdr's own catalog limit.
  machineAlias = n: "herdr-${n}";
  machineId = n: builtins.substring 0 32 (builtins.hashString "sha256" ("herdr-nixos:" + n));

  # Rows expected to be dialable: enabled ones. The hostname/knownHosts assertions below
  # run over exactly these (disabled rows are exempt - see the off-boarding comment),
  # while the merge fragment emits EVERY resolved row (disabled twins replace ghosts) and
  # the ssh blocks only exist for rows that have an address.
  enabledMachines = lib.filterAttrs (_: m: m.enabled) resolvedMachines;

  # known_hosts lines re-keyed to the alias: the connection dials HostName <ip> with
  # HostKeyAlias <alias>, so the pin line must start with the alias (ssh matches the
  # alias, not the address, when HostKeyAlias is set - the same trick ~/.ssh/config uses
  # for r4uai00's lab-IP churn).
  machineKnownHosts = n: m: let
    rekey = line: let
      parts = builtins.match "[^ ]+ (.*)" line;
    in
      if parts == null
      then throw "MODULES.services.herdr.machines.${n}: knownHosts line is not '<host> <type> <key>': ${line}"
      else "${machineAlias n} ${builtins.head parts}";
  in
    map rekey m.knownHosts;

  # The catalog fragment herdr's per-user endpoints.json is merged from. Field order and
  # shape per SavedSshEndpoint (deny_unknown_fields!): id/label/target/session/enabled.
  # EVERY resolved row is emitted - including disabled rows without an address: the target
  # is just the alias string, and the disabled twin is precisely what replaces a ghost
  # (previously-derived, now-retired) row out of users' catalogs. Address facts are only
  # required for what ssh must actually dial (enabledMachines above).
  endpointsFragment = builtins.toJSON {
    version = 1;
    selected_profile = null;
    ssh =
      lib.mapAttrsToList (
        n: m: {
          id = machineId n;
          label = m.label;
          # The alias, not user@host: ssh config (blocks below) is what pins identity,
          # user, port and the host key; a plain IP target would bypass all of it.
          target = machineAlias n;
          session = m.session;
          enabled = m.enabled;
        }
      )
      resolvedMachines;
  };

  # ssh client blocks per machine: the alias resolves to the declared address/user/port and
  # to /etc/herdr/known-hosts; the uid-0 Match (znapzend's pattern, same file's lessons)
  # pins the HUB identity for root only, so akos on legion5 keeps his own keys and an
  # unprivileged ssh never grabs the hub key. The hub key exists only where sshKeySecret is
  # set; the blocks (alias + known_hosts) exist everywhere, because every herdr user on
  # every host gets the same catalog and must be able to dial every entry.
  machineSshBlocks = n: m: let
    hostLines = builtins.concatStringsSep "\n" (
      [
        "Host ${machineAlias n}"
        "  HostName ${m.hostname}"
        "  User ${m.user}"
        "  HostKeyAlias ${machineAlias n}"
        "  UserKnownHostsFile /etc/herdr/known-hosts"
        "  StrictHostKeyChecking yes"
      ]
      ++ lib.optionals (m.port != null) ["  Port ${toString m.port}"]
    );
    # Nix is strict: the pin lines may not interpolate sshKeySecret/.path at all when the
    # option is null ("" would still evaluate the secret path and throw), hence if/else.
    pinLines =
      if cfg.sshKeySecret == null
      then ""
      else ''

        Match originalhost ${machineAlias n} exec "test \"$(id -u)\" = 0"
          IdentityFile ${config.sops.secrets.${cfg.sshKeySecret}.path}
          IdentitiesOnly yes
          BatchMode yes
      '';
  in "${hostLines}${pinLines}";

  # Seed each user's config files. tmpfiles type C (not C+) copies the source only when the
  # target does not already exist, which is the behaviour these two programs need: both write
  # back into their own config (the TUI records onboarding = false on first run, the app's
  # agent-editable AGENTS.md surface is the whole point), and a rule that re-copied on every
  # boot would silently revert those edits on the next switch.
  userConfigSeeds = name: let
    ua = config.users.users.${name} or null;
    uCfg = cfg.users.${name};
    seed = dest: src: "C ${dest} 0600 ${name} ${ua.group} - ${src}";
  in
    # Same guard as userDirs, and the same ordering requirement: the `d` rules are emitted
    # before these `C` ones because systemd-tmpfiles applies a file's lines top-down, and a
    # copy into a directory that does not exist yet silently no-ops.
    if ua == null
    then []
    else
      (lib.optionals (uCfg.cli.enable && configToml uCfg != "") [
        (seed "${ua.home}/.config/herdr/config.toml" (pkgs.writeText "herdr-tui-${name}.toml" (configToml uCfg)))
      ])
      ++ (lib.optionals (uCfg.app.enable && uCfg.app.coreConfig != {}) [
        (
          seed "${ua.home}/.config/herdr-core/config.toml"
          (pkgs.writeText "herdr-core-${name}.toml" (toToml uCfg.app.coreConfig))
        )
      ]);

  # ── agent skills: teach the fleet's harnesses hc/herdr ─────────────────────
  # The skill text ships INSIDE each pinned package's source tree (verified at
  # this pin: skills/herdr-core/SKILL.md in the herdr-core src, skills/herdr/
  # SKILL.md in the herdr TUI src), so the text an agent learns can never be
  # newer than the binary it talks to. Copying (tmpfiles C+, create-once like
  # the config seeds above) rather than symlinking into the store, because
  # several scanners readdir their skills root with entry types that make a
  # symlinked skill dir luck-dependent (herdr's own integration installer
  # copies for the same reason). Create-once has a real consequence: an
  # upstream skill rewrite lands only on FRESH installs and in homes where the
  # copy was removed - deliberate, the same trade the AGENTS.md seed makes:
  # agents edit their skills (skill-creator), a re-copy would silently revert
  # those edits on the next switch.
  herdrSkillSources = lib.filterAttrs (_: v: v != null) {
    # hc (sub-agents, terminals, background tasks): the delegation surface.
    herdr-core =
      if corePkg != null
      then "${corePkg.src}/skills/herdr-core"
      else null;
    # The herdr TUI's pane control - relevant to agents INSIDE TUI panes.
    herdr =
      if herdrPkg != null
      then "${herdrPkg.src}/skills/herdr"
      else null;
  };

  # Each harness's USER-level skill-discovery root, relative to the account's
  # home (hermes' is the service state dir, see the special-casing below).
  # Every line verified against the pinned binary/package or the product's own
  # docs, never against another harness's convention:
  #   omp      scanSkillsFromDir(join(getAgentDir(),"skills")) - the 18.16.0
  #            bundle's discovery/builtin.ts user-level scan; proven on disk
  #            2026-11-12 (a copy under ~/.omp/agent/skills listed by
  #            `omp skill list`).
  #   pi       agentRoots = [join(agentDir,"skills"), ...] in the 1.5.0
  #            bundle (chunk-44DLKSKE.js); same layout as omp (its fork).
  #   opencode docs.opencode.ai/docs/skills: global = ~/.config/opencode/skills
  #            (and ~/.claude/skills, ~/.agents/skills as compat roots).
  #   kilo     PROBED on kilo-cli 7.8.27 with `kilo debug skill`: a copy at
  #            ~/.config/kilo/skills/herdr-probe/SKILL.md was discovered with
  #            that exact location; the OpenCode-fork layout matches.
  #   codex    ~/.codex/skills/<name>/SKILL.md: codex itself creates and fills
  #            that root (the on-disk .system/ skills, imagegen & friends) -
  #            user skills are the top-level siblings.
  #   claude   ~/.claude/skills: claude code's root (also read by kilo/amp
  #            compat scans).
  #   amp      ampcode.com/docs/customize/skills precedence list entry 3 =
  #            ~/.config/amp/skills - the amp-ONLY root, chosen over the
  #            shared ~/.agents/skills (#2) to keep amp's copy from showing up
  #            in other tools' scans.
  #   cline    ~/.agents/skills: the global root cline's own skill install
  #            code writes (the 3.0.74 binary's "Cannot install skill globally
  #            because ~/.agents/skills is not writable" guard); cline has no
  #            private root, so this one copy is deliberately visible to
  #            omp/opencode/amp's compat scans too - each of those dedupes or
  #            precedence-resolves a same-named skill against its own copy.
  #   hermes   $HERMES_HOME/skills: hp's live agent already discovers its
  #            skills there (/var/lib/hermes/.hermes/skills/*/SKILL.md).
  # A skill added here only fires where the matching harness MODULE is enabled
  # (the derivation below), so this table costs nothing on hosts without it.
  herdrSkillRoots = {
    omp = ".omp/agent/skills";
    pi = ".pi/agent/skills";
    opencode = ".config/opencode/skills";
    kilo = ".config/kilo/skills";
    codex = ".codex/skills";
    claude = ".claude/skills";
    amp = ".config/amp/skills";
    cline = ".agents/skills";
    hermes = ".hermes/skills";
  };

  # Which (account, harness) pairs exist ON THIS HOST, derived from the harness
  # modules' own users lists - that is the "all my configured harnesses" the
  # option docs promise; nothing here knows a hostname. Two exceptions to the
  # users-list shape, both by those modules' design: opencode renders a
  # system-wide config and identifies its consumer through secretOwner, and
  # hermes is a SERVICE account whose HOME is its stateDir (upstream creates
  # .hermes inside it).
  skillWanted = let
    # rows: { harness user } - derived pairs plus the declared extras, minus
    # whatever `disable` names.
    pairs =
      (
        (lib.optionals (config.MODULES.services.omp.enable or false)
          (map (u: {
              harness = "omp";
              user = u;
            })
            config.MODULES.services.omp.users))
        ++ (lib.optionals (config.MODULES.services.pi.enable or false)
          (map (u: {
              harness = "pi";
              user = u;
            })
            config.MODULES.services.pi.users))
        ++ (lib.optionals (config.MODULES.services.opencode.enable or false) [
          {
            harness = "opencode";
            user = config.MODULES.services.opencode.secretOwner;
          }
        ])
        ++ (lib.optionals (config.MODULES.services.kilo.enable or false)
          (map (u: {
              harness = "kilo";
              user = u;
            })
            config.MODULES.services.kilo.users))
        ++ (lib.optionals (config.MODULES.services.codex.enable or false)
          (map (u: {
              harness = "codex";
              user = u;
            })
            config.MODULES.services.codex.users))
        ++ (lib.optionals (config.MODULES.services.claudeCode.enable or false)
          (map (u: {
              harness = "claude";
              user = u;
            })
            config.MODULES.services.claudeCode.users))
        ++ (lib.optionals (config.MODULES.services.amp.enable or false)
          (map (u: {
              harness = "amp";
              user = u;
            })
            config.MODULES.services.amp.users))
        ++ (lib.optionals (config.MODULES.services.cline.enable or false)
          (map (u: {
              harness = "cline";
              user = u;
            })
            config.MODULES.services.cline.users))
        ++ (lib.optionals (config.services.hermes-agent.enable or false) [
          {
            harness = "hermes";
            user = config.services.hermes-agent.user;
          }
        ])
      )
      ++ cfg.skills.extra;
    # The pairs whose account exists (a derived row with no account means the
    # harness's CONSUMER is not really here - hermes without sshAccess creates
    # no user at all; a declared extra with a missing user fails eval below) -
    # exposed at the spine so the assertions can distinguish "nothing to teach"
    # from "would install but the pin lacks the package".
    resolvable = lib.filter (p: config.users.users ? ${p.user}) pairs;
  in
    lib.filter (p: !builtins.elem p.harness cfg.skills.disable) resolvable;

  skillRules = let
    rule = p: let
      ua = config.users.users.${p.user} or null;
      # hermes' skill root hangs off the SERVICE state dir, not the account's
      # home (the module's hermesHome doctrine); for hermes the `user` field is
      # only the chown target, and the state dir's own modes are the
      # hermes-agent module's business - we only add `skills` below it.
      base =
        if p.harness == "hermes"
        then "${config.services.hermes-agent.stateDir}/${herdrSkillRoots.${p.harness}}"
        else "${ua.home}/${herdrSkillRoots.${p.harness}}";
      # The harness root (e.g. ~/.codex, ~/.agents, ~/.omp/agent) and its
      # skills dir, created 0700 BEFORE copying: C+ would build a not-yet-
      # existing dir with tmpfiles' default 0755 (measured 2026-11-12), and
      # homes laid out before the harness first ran have no such dir yet. The
      # roots' OWN parents are already 0700 by other units' rules (~/.config
      # via userDirs, ~/.omp and ~/.pi via the harness modules) or app-
      # created. Hermes is exempt: its .hermes tree (2700 skills dir included,
      # measured on hp 2026-11-12) is created and owned by the agent itself,
      # and a `d` rule RE-MODES existing directories - a 0700 here would
      # silently strip that setgid on every switch. C+ inside the private
      # 0700 .hermes needs no help.
      rootRules =
        if p.harness == "hermes"
        then []
        else [
          "d ${root} 0700 ${p.user} ${ua.group} -"
          "d ${base} 0700 ${p.user} ${ua.group} -"
        ];
      root = dirOf base;
    in
      # C+ (copy, create parents): the only tmpfiles verb that copies a whole
      # skill dir; verified on this host 2026-11-12 (recursive dir-source C+
      # creates the full destination tree with the given owner, does NOT
      # re-copy or re-chmod once the target exists, and never touches the
      # mode/owner of an EXISTING parent). The 0700 skill dirs and copied dirs
      # match userDirs/kilo.nix; SKILL.md inside keeps its store 0444 bit,
      # which the scanner reads through the owner.
      rootRules
      ++ map (prod: "C+ ${base}/${prod} 0700 ${p.user} ${ua.group} - ${herdrSkillSources.${prod}}")
      cfg.skills.products;
  in
    lib.optionals cfg.skills.enable (lib.concatMap rule skillWanted);
  # ── cli.service: the TUI server for the no-linger accounts ───────────────
  # Why a system unit at all: herdr's own remote bootstrap spawns NO remote server
  # for an account without a systemd user manager (measured 2026-11-10 against hp's
  # linger-less hermes: the client authenticated and the bridge ran, but `ps`
  # during the attach showed no server ever starting), and this account must never
  # get a user manager (modules/services/hermes-agent.nix: the gateway would route
  # cron workers through systemd-run --user, out of the sandbox). So the unit owns
  # the server and every client - hub, laptop, direct ssh - only attaches to the
  # live $HOME/.config/herdr/herdr.sock (measured: against a server already up, the
  # same --remote attach reached the pane UI; the pane shell drew a real prompt).
  #
  # `herdr server` runs in the FOREGROUND (measured: `timeout 4 herdr server` held
  # the tty for the full 4s and rc=124), so Type=simple: systemd tracks the real
  # PID, the unit cgroup owns the panes' whole tree, and a unit stop SIGTERMs
  # everything - no orphans, no stale-socket adoption race inside the unit's own
  # lifecycle. TERM is pinned in the unit env because a systemd service has none,
  # and panes inherit it (an unset TERM made the smoke-test panes render as dumb).
  # preStart still ADOPTS servers the unit does not own (a client that raced a dead
  # server may have left one reparented to PID 1): stop via the API, wait out the
  # "herdr server is already running" guard, let systemd exec ours.
  # restartTriggers + sysinit-reactivation bounce the server on config/pin changes
  # and survive the 26.05 switcher's skipped-start bug (the 2026-11-10
  # endpoints-merge lesson); pane state is restored from ~/.local/state/herdr the
  # same way a reboot restores root's.
  herdrServerUnits = builtins.listToAttrs (
    map (
      name:
        lib.nameValuePair "herdr-server-${name}" {
          description = "herdr TUI server for ${name} (fleet unit; account deliberately has no linger)";
          after = ["systemd-tmpfiles-setup.service"];
          wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
          unitConfig.StopWhenUnneeded = false;
          restartTriggers =
            lib.optionals (herdrPkg != null) [herdrPkg]
            ++ lib.optionals (
              config.users.users ? ${name}
              && configToml cfg.users.${name} != ""
            ) [
              (pkgs.writeText "herdr-tui-${name}.toml" (configToml cfg.users.${name}))
            ];
          preStart = let
            herdr = "${herdrPkg}/bin/herdr";
            # ExecStartPre runs as User= too (no + prefix), so no runuser: the API
            # client below IS this user. And `herdr status server` exits 0 running
            # AND stopped (measured) - the verdict is in the output's first line.
            check = "${herdr} status server 2>/dev/null | head -n1 | grep -q '^status: running\$'";
          in ''
            set -u
            if ${check}; then
              ${herdr} server stop || true
              # Wait for the foreign daemon to be really gone (10x0.5s) before
              # systemd execs ours - `herdr server` refuses while one lives.
              for i in 1 2 3 4 5 6 7 8 9 10; do
                ${check} || break
                sleep 0.5
              done
            fi
          '';
          serviceConfig = {
            Type = "simple";
            User = name;
            # Panes default their cwd to the SERVER's cwd - without this they
            # would open in systemd's default (/), not the account's home.
            WorkingDirectory = (config.users.users.${name} or {}).home or "/";
            # `or` guard: a cli.service entry naming an unknown user must trip the
            # managedUsers assertion (it names the user), not die here on Group.
            Group = (config.users.users.${name} or {group = name;}).group;
            # systemd gives User= services HOME/USER/LOGNAME but no TERM, and its
            # default PATH misses the per-user profile (/etc/profiles/per-user/
            # <user>/bin - where hermes-agent.nix puts the hermes CLI) that a
            # login shell would add. Panes inherit the server's environment, and
            # `shell_mode = "login"` was measured NOT to fix this (2026-11-10:
            # login-shell_mode pane still had no hermes on PATH), so the unit
            # carries the full PATH every pane needs: user profile first, then
            # the system profile (agentTools, herdr itself) and the FHS fallbacks.
            # TERM: a systemd service has none and herdr starts unattached panes
            # at "dumb"; attach a client before launching TUI agents and they get
            # the client's real terminal, this pin just keeps pre-attach panes
            # sane.
            Environment = [
              "TERM=xterm-256color"
              "PATH=/etc/profiles/per-user/${name}/bin:/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
            ];
            ExecStart = "${herdrPkg}/bin/herdr server";
            Restart = "on-failure";
            RestartSec = "5s";
            # Panes run as this uid anyway; NoNewPrivileges + 0077 only harden the
            # obvious (no setuid games; sockets/scrollback files group/world-dark,
            # same reasoning as the tmpfiles 0700 dirs above).
            NoNewPrivileges = true;
            UMask = "0077";
            TimeoutStopSec = 30;
          };
        }
    )
    (lib.attrNames (lib.filterAttrs (_: u: u.enable && u.cli.service) cfg.users))
  );
in {
  options.MODULES.services.herdr = {
    enable = mkEnableOption "herdr: the TUI, the desktop app, and the herdr-core backend they run on";

    installCli = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Put the herdr TUI (bin/herdr) on the system PATH. Set false on a machine that only
        needs to be an SSH target for hc - and vice versa. Both default true, since the
        point of the fleet setup is that either program can drive either machine.
      '';
    };

    installCore = mkOption {
      type = types.bool;
      # Default "install it when this pin has it": herdr-core is newer than the fleet's
      # nixpkgs pins, so a flat true would fail the assertion on hosts that only ever wanted
      # the TUI. Set true explicitly where the app stack is wanted, and the assertion then
      # points at the one command that fixes it.
      default = pkgs-unstable ? herdr-core;
      description = ''
        Put herdr-core (bin/hc, bin/herdr-core) on the system PATH. This is the backend the
        desktop app attaches to; without it on a machine, `hc machine add <that host>` has
        to install a release binary over SSH instead of using the packaged one.

        Defaults to whether the nixpkgs-unstable pin carries the package at all, so a pin
        from before herdr-core landed still builds. Set true to demand it: an assertion then
        reports a pin too old to have it rather than quietly installing nothing.
      '';
    };

    installApp = mkOption {
      type = types.bool;
      default = pkgs-unstable ? herdr-desktop;
      description = ''
        Install the Herdr desktop app (pkgs.herdr-desktop: bin/herdr-app, its .desktop
        entry and icon). The app needs a Wayland/X11 session and a working Vulkan driver,
        so turn this off on the headless servers - it buys nothing there and pulls the GPU
        library set into their system closure. Like installCore, this defaults to "whatever
        the pin has", so set it true where the GUI is actually wanted.
      '';
    };

    agents = mkOption {
      type = types.attrsOf (types.submodule agentEntrySubmodule);
      default = {
        # The fleet harnesses herdr-app's built-in table lacks (verified
        # against v0.1.10's defaults/programs.json 2026-11-09: claude, codex,
        # pi, opencode, amp, hermes, ... are in; omp, cline and kilo are not).
        omp = {name = "oh-my-pi";};
        cline = {name = "Cline";};
        kilo = {name = "Kilo Code";};
        # UltraTrainer (datalabHarness web harness): the menu row probes `command -v
        # ultra-trainer`, which resolves to the datalab account's shim -> the cluster
        # tmux (see datalab-harness agentShim). Its pane is the training app's process;
        # the UI itself rides https://<subdomain>.datalab.hp, not the pane.
        ultra-trainer = {name = "UltraTrainer";};
      };
      defaultText = literalExpression ''
        { omp, cline, kilo } - the fleet harnesses upstream's table has no entry for
      '';
      description = ''
        Entries for the app's ~/.config/herdr-app/programs.json (its agent menu
        and pane tiles). Rendered as a fragment and deep-merged over each app
        user's file at activation (user entries survive, named ones
        re-asserted); the running app hot-reloads the file. The icon default
        points at the shipped generic bot glyph, since upstream carries none
        for these.
      '';
    };

    users = mkOption {
      type = types.attrsOf (types.submodule userSubmodule);
      default = {};
      example = literalExpression ''
        {
          akos = {
            enable = true;
            cli.enable = true;
            app.enable = true;
          };
        }
      '';
      description = ''
        Users to lay out herdr state for, keyed by NixOS username. Each user chooses the TUI
        (cli) and/or the app (app) independently; enabling this attrset for a name also
        turns on that user's linger so the servers exist at boot rather than only after a
        login. Nothing here starts a server - both programs do that themselves.
      '';
    };

    skills = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install herdr's own agent skill (SKILL.md, shipped inside the pinned
          package sources) into every configured harness's skill-discovery
          root, so agents inside herdr panes learn `hc`/herdr without any
          manual step. On fleet-wide by default (the fleet's whole point is
          agents coordinating through hc); hosts that want an agent to NOT
          know about herdr list it in `disable`.
        '';
      };

      products = mkOption {
        type = types.listOf (types.enum ["herdr" "herdr-core"]);
        # "does the pin have it" (the install* doctrine): herdr-core teaches
        # hc (sub-agents, terminals, background tasks - the delegation surface
        # fleet agents actually need), herdr the TUI's pane control. Both
        # self-scope via their description ("use only when..."), so shipping
        # both costs context only when relevant. Each names the package whose
        # source carries it; a pin too old to have herdr-core drops that skill
        # rather than failing a host that merely enabled the module, while an
        # EXPLICIT products request the pin cannot serve fails the assertion
        # with the flake-update hint.
        default = lib.optionals (herdrPkg != null) ["herdr"] ++ lib.optionals (corePkg != null) ["herdr-core"];
        defaultText = literalExpression ''
          [ "herdr" ] ++ [ "herdr-core" ], each only when pkgs-unstable carries it
        '';
        description = "Which of the two shipped skills to install (see the derivation comment in this file for what each teaches).";
      };

      disable = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["cline"];
        description = ''
          Harness names to skip even though the harness is enabled on this host.
          Names must be one of the table's keys (asserted); an agent whose skill
          install you want gone keeps its old copy - tmpfiles never overwrites
          an existing file (same create-once doctrine as the config seeds).
        '';
      };

      extra = mkOption {
        type = types.listOf (types.submodule (_: {
          options = {
            user = mkOption {
              type = types.str;
              description = "Account to install for (must exist on this host - asserted).";
            };
            harness = mkOption {
              type = types.str;
              description = "Which harness's skill root to write (a table key - asserted).";
            };
          };
        }));
        default = [];
        example = literalExpression ''[ { user = "datalab"; harness = "omp"; } ]'';
        description = ''
          Installs the auto-derivation cannot know about: an account that runs a
          harness outside that harness module's `users` list. The table keys are
          documented on `herdrSkillRoots` in this file.
        '';
      };
    };

    hermesIntegration = mkEnableOption ''
      teach herdr to recognize the Hermes agent fork's CLI in herdr panes, via herdr's own
      hermes plugin (`herdr integration install hermes`, run as the hermes service account so
      it lands in $HERMES_HOME). Requires MODULES.services.hermes-agent.enable.

      WHY this is needed at all: herdr identifies a pane's agent by the pane child's PROCESS
      NAME (src/detect/mod.rs: "hermes" | "hermes-agent" => Agent::Hermes). The Nix package is
      a venv install, and its `hermes` entry point is a bash wrapper that execs the venv's
      python - so argv0 of the live process is `python3.14`, not `hermes`, and the name-based
      detection can never match (measured on hp 2026-11-26: a `hermes` TUI in an hp pane shows
      up as a plain shell). herdr's answer is its own integration plugin rather than a
      re-spawn shim: the installed __init__.py registers fork hooks (on_session_start /
      on_session_reset / pre_llm_call) and reports the pane's session identity by calling
      `herdr pane report-agent-session` whenever HERDR_ENV=1 + HERDR_PANE_ID are set - i.e.
      exactly for interactive `hermes` runs launched from herdr panes, and never for the
      gateway/cron paths, which have no pane env.
    '';

    machines = mkOption {
      type = types.attrsOf (types.submodule machineEntrySubmodule);
      # attrsOf-defaults-{} + field-wise merge (the attrsOf default trap, AGENTS.md):
      # a host naming machines.hp.user MUST NOT lose the auto-derived rows, and one row
      # overriding one field must not lose the fleet facts for that row.
      default = {};
      example = literalExpression ''
        # Off-tailnet host the flake cannot see (the r4uai00 pattern): the two required
        # fields are the address and its pinned public host key(s).
        {
          r4uai00 = {
            hostname = "10.210.0.10";
            user = "apapp";
            knownHosts = [ "10.210.0.10 ssh-ed25519 AAAA..." ];
          };
          # A tailnet host whose hop should run as a different user:
          akos01.user = "herdr";
        }
      '';
      description = ''
        The DECLARED TUI machine catalog: rows here, plus the auto-derived fleet rows
        (every OTHER host whose own config enables MODULES.services.herdr - address and
        host keys read from nixosConfigurations like service-graph's peer tables), are
        merged into every cli-user's ~/.local/state/herdr/client/endpoints.json. Names
        collide on purpose: a machines.<name> row overrides the fleet-derived row field by
        field. Herdr hot-reloads the file (1s poll, verified against v0.9.x
        catalog_reload.rs 2026-11-09), so open clients see new machines without restart,
        and every host's catalog carries the same deterministic profile ids - hp-as-hub
        and legion5 show identical machine sets with zero manual `machine add`.
        The app/herdr-core runtime registry is separate; coreRegistry synchronizes it
        without copying local core identity or terminal state.
      '';
    };

    coreRegistry = {
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Account whose hc machine registry participates in two-way Syncthing sync.
          Null disables the bridge. Only portable permanent SSH machine records are
          shared, never via commands, temporary targets, local identity or terminals.
          Participants automatically share the dedicated registry folder; use hc
          machine add/rm/rename normally and allow a timer plus Syncthing interval.
        '';
      };
      session = mkOption {
        type = types.strMatching "[A-Za-z0-9_-][A-Za-z0-9._-]*";
        default = "default";
        description = "Local HC_SESSION whose machines.json is synchronized; remote records retain their own session.";
      };
    };

    sshKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "herdr/hub_ssh_key";
      description = ''
        sops key (in sops/secrets.yaml) whose plaintext is an OPENSSH-format private key,
        rendered root:root 0400 and pinned (IdentityFile + IdentitiesOnly + BatchMode) as
        the identity of EVERY root-originated `ssh herdr-*` connection on this host - the
        hub's outward key. Only the HUB host sets it (hp); other hosts dial their catalog
        entries with the operator's own keys. The matching public half belongs in the
        targets' root authorized_keys (profiles/global.nix).
      '';
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions =
          # A user entry naming an account this host has no idea about is the common typo (hp and
          # akos01 define no akos user at all - the akos module is opt-in via USERS.akos.enable).
          (lib.mapAttrsToList (name: _: {
              assertion = config.users.users ? ${name};
              message = "MODULES.services.herdr.users.${name}: no such user in config.users.users - declare the user (or enable USERS.akos) or drop this entry.";
            })
            managedUsers)
          # Each of the three pieces is separately installable, so a missing one names exactly
          # what to do rather than failing later in the build.
          ++ lib.optionals cfg.installCli [
            {
              assertion = herdrPkg != null;
              message = "MODULES.services.herdr.installCli: pkgs-unstable.herdr is missing from this flake's nixpkgs-unstable pin. Run 'nix flake update nixpkgs-unstable' (the package is new).";
            }
          ]
          ++ lib.optionals cfg.installCore [
            {
              assertion = corePkg != null;
              message = "MODULES.services.herdr.installCore: pkgs-unstable.herdr-core is not in this flake's nixpkgs-unstable pin (rev 1c89083e451e predates it; the branch has had it since). Run 'nix flake update nixpkgs-unstable', or set installCore = false on a host that only needs the TUI.";
            }
          ]
          ++ lib.optionals cfg.installApp [
            {
              assertion = appPkg != null;
              message = "MODULES.services.herdr.installApp: pkgs-unstable.herdr-desktop is not in this flake's nixpkgs-unstable pin (same rev cutoff as herdr-core). Run 'nix flake update nixpkgs-unstable', or set installApp = false on a headless host that needs no GUI.";
            }
          ]
          # The hermes integration writes into the hermes service's state dir as the hermes
          # uid and runs herdr's installer binary - both must really exist here.
          ++ lib.optionals cfg.hermesIntegration [
            {
              assertion = config.MODULES.services.hermes-agent.enable or false;
              message = "MODULES.services.herdr.hermesIntegration needs MODULES.services.hermes-agent.enable (it installs the plugin into the hermes service's $HERMES_HOME as the hermes account).";
            }
            {
              assertion = herdrPkg != null;
              message = "MODULES.services.herdr.hermesIntegration: pkgs-unstable.herdr is missing from this flake's nixpkgs-unstable pin. Run 'nix flake update nixpkgs-unstable' (the hermes integration target needs herdr >= the release that ships it).";
            }
          ]
          ++ lib.optionals registryEnabled [
            {
              assertion = registryAccount != null && builtins.hasAttr cfg.coreRegistry.user managedUsers;
              message = "MODULES.services.herdr.coreRegistry.user must name an enabled herdr user with a local account.";
            }
            {
              assertion = cfg.installCore && corePkg != null;
              message = "MODULES.services.herdr.coreRegistry requires installCore and herdr-core in nixpkgs-unstable.";
            }
          ]
          # Skills: a disabled or unknown harness name is a typo in disable/extra, and an
          # extra row's user must exist here (the same shape as the users.${name} check
          # above - fail eval with the name, don't fail obscurely inside tmpfiles).
          ++ lib.optionals cfg.skills.enable (
            (map (h: {
                assertion = builtins.elem h (builtins.attrNames herdrSkillRoots);
                message = "MODULES.services.herdr.skills.disable: '${h}' is not a known harness (known: ${lib.concatStringsSep ", " (builtins.attrNames herdrSkillRoots)}).";
              })
              cfg.skills.disable)
            ++ (map (r: {
                assertion = builtins.elem r.harness (builtins.attrNames herdrSkillRoots);
                message = "MODULES.services.herdr.skills.extra: harness '${r.harness}' is not a known harness (known: ${lib.concatStringsSep ", " (builtins.attrNames herdrSkillRoots)}).";
              })
              cfg.skills.extra)
            ++ (map (r: {
                assertion = config.users.users ? ${r.user};
                message = "MODULES.services.herdr.skills.extra: user '${r.user}' has no account on this host.";
              })
              cfg.skills.extra)
            # A product named in `products` whose package the pin lacks (or,
            # for a non-null pin, whose source has no skills/ dir) would make
            # every rule below throw an opaque "attribute herdr missing" from
            # inside the tmpfiles list - name the flake update instead.
            ++ (map (prod: {
                assertion = herdrSkillSources ? ${prod};
                message = "MODULES.services.herdr.skills.products includes '${prod}' but pkgs-unstable.${prod} is not in this flake's pin (or its source ships no skills/${prod}). Run 'nix flake update nixpkgs-unstable', or drop it from products.";
              })
              cfg.skills.products)
          )
          # Catalog rows must be dialable WITHOUT prompts (herdr's background reconnects are
          # BatchMode): an addressless or keyless row would leave every client showing a dead
          # "Attention" machine, so it fails eval instead. Fleet-derived rows always have both
          # when the host declares its tailnet facts. DISABLED rows are exempt: that is the
          # declarative off-boarding path (machines.<name>.enabled = false re-asserts the row
          # disabled in everyone's endpoints.json, hiding it from the sidebar, with no facts
          # needed - a row the fleet has retired may genuinely have no address anymore).
          ++ (lib.mapAttrsToList (
              n: m: {
                assertion = m.hostname != null;
                message = "MODULES.services.herdr.machines.${n}: no address - ${n} is not a flake host with MODULES.networking.tailscale.hostIP, so set machines.${n}.hostname (and knownHosts) explicitly, or machines.${n}.enabled = false to retire it.";
              }
            )
            enabledMachines)
          ++ (lib.mapAttrsToList (
              n: m: {
                assertion = m.knownHosts != [];
                message = "MODULES.services.herdr.machines.${n}: no known_hosts lines - ${n} has no MODULES.networking.sshClient.hostKeys in the flake, so declare machines.${n}.knownHosts (public keys: ssh-keyscan <addr> over a trusted path, 2026-11-03 doctrine). Hub ssh with StrictHostKeyChecking=yes must fail closed, never TOFU.";
              }
            )
            enabledMachines)
          ++ (lib.mapAttrsToList (
              n: m: {
                assertion = m.session != "" && m.session != "." && m.session != ".." && builtins.match "[A-Za-z0-9._-]+" m.session != null && builtins.stringLength m.session <= 64;
                message = "MODULES.services.herdr.machines.${n}.session: ${builtins.toJSON m.session} violates upstream's session-name charset [A-Za-z0-9._-], <= 64 bytes (herdr validate_name) - the whole catalog would fail to parse remotely.";
              }
            )
            cfg.machines)
          # herdr's own catalog limits (MAX_PROFILES=64, MAX_LABEL_BYTES=128): exceed them and
          # every user's endpoints.json becomes unloadable - catch it at eval, not in the TUI.
          ++ [
            {
              assertion = builtins.length (builtins.attrNames resolvedMachines) <= 64;
              message = "MODULES.services.herdr.machines: ${toString (builtins.length (builtins.attrNames resolvedMachines))} rows, herdr's catalog accepts at most 64.";
            }
          ]
          # The catalog target is the ssh alias ("herdr-<name>"); a name with spaces, ':' or
          # '@' would break the ssh Host/Match blocks and herdr's target validator, so the
          # attr key itself is constrained.
          ++ (lib.mapAttrsToList (
              n: _: {
                assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n != null;
                message = "MODULES.services.herdr.machines key ${builtins.toJSON n} is not a valid ssh Host pattern token ([A-Za-z0-9][A-Za-z0-9._-]*).";
              }
            )
            cfg.machines);

        # Linger for every managed user. Neither server depends on us to start it, but both
        # need the user manager to exist at boot: herdr-core puts its client socket under
        # /run/user/<uid>/herdr-core/ and, with no user manager, falls back to the state dir and
        # warns "no systemd user manager here: the core ends with whatever started it" - i.e.
        # every agent dies on logout. Enabling a user's herdr state therefore always enables
        # their linger.
        # EXCEPT for cli.service users (hp's hermes): that account must NOT get a user
        # manager - the Hermes gateway would route its cron workers through
        # systemd-run --user and out of the unit sandbox (see the mkForce false in
        # modules/services/hermes-agent.nix) - and the TUI needs nothing from one: its
        # socket is ~/.config/herdr/herdr.sock, tmpfs-independent, and the server is
        # kept up by the cli.service unit below instead of by linger.
        users.users =
          lib.mapAttrs (
            name: u: lib.optionalAttrs (!u.cli.service) {linger = true;}
          )
          managedUsers;

        # The hub's OUTGOING identity (hp only, where sshKeySecret is set). OPENSSH private key
        # text (NOT base64 like znapzend's - sops renders it verbatim), root-only: the ssh
        # Match blocks below point IdentityFile straight at it. sops decrypts onto the tmpfs
        # mount; nothing else reads it.
        # (mkIf wraps the WHOLE attr binding: `sops.secrets.${cfg.sshKeySecret}` evaluates the
        # attr name first, and interpolation of null throws before mkIf could discard it.)
        sops.secrets = lib.mkIf (cfg.sshKeySecret != null) {
          ${cfg.sshKeySecret} = {
            sopsFile = ../../sops/secrets.yaml;
            key = cfg.sshKeySecret;
            owner = "root";
            group = "root";
            mode = "0400";
          };
        };

        # Per-machine ssh client blocks (aliases, pins, hub identity) into the single-owner
        # /etc/ssh/ssh_config. See modules/networking/ssh-client.nix for WHY this is a block
        # contribution; see modules/system/znapzend.nix for why the identity pin is a
        # `Match originalhost ... exec uid-0` (NOT `Match host`: HostName rewrites resolve it
        # before matching - measured hp 2026-10-26) and why accept-new/yes matters to BatchMode.
        MODULES.networking.sshClient.blocks =
          lib.mapAttrsToList (
            n: m: machineSshBlocks n m
          )
          (lib.filterAttrs (_: m: m.hostname != null) resolvedMachines);

        # The per-user directories and config seeds. Deferred into this option's *value* for
        # the usual reason: computing them needs the merged cfg.users, and reading cfg.users at
        # the module spine (in the top-level let) while this module still supplies its own
        # config closes that into infinite recursion. Same shape as
        # modules/services/paseo-machine.nix.
        systemd.tmpfiles.rules =
          builtins.concatLists (map userDirs (lib.attrNames managedUsers))
          ++ builtins.concatLists (map userConfigSeeds (lib.attrNames managedUsers))
          ++ skillRules
          ++ lib.optionals registryEnabled [
            "d ${registryShare} 0700 ${registrySyncthingUser} ${config.users.users.${registrySyncthingUser}.group} -"
            "d ${registryLedger} 0700 root root -"
            "d ${registryAccount.home}/.local 0700 ${cfg.coreRegistry.user} ${registryAccount.group} -"
            "d ${registryAccount.home}/.local/state 0700 ${cfg.coreRegistry.user} ${registryAccount.group} -"
            "d ${registryAccount.home}/.local/state/herdr-core 0700 ${cfg.coreRegistry.user} ${registryAccount.group} -"
            "d ${registryState} 0700 ${cfg.coreRegistry.user} ${registryAccount.group} -"
          ];

        # Syncthing on a dedicated share, not /root or the whole hc state directory:
        # hp's service UID/private-user namespace cannot traverse /root, and even on
        # the laptop the core identity/terminal state must never be made shareable.
        MODULES.services.syncthing.shares = lib.mkIf registryEnabled [
          {
            path = registryShare;
            ignorePatterns = map (n: "!/${n}.json") (builtins.attrNames registryParticipants) ++ ["*"];
          }
        ];

        systemd.services.herdr-registry-sync = lib.mkIf registryEnabled {
          description = "Merge portable hc machine registries through Syncthing";
          after = ["systemd-tmpfiles-setup.service"];
          wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            ExecStart = "${pkgs.python3}/bin/python3 ${./herdr/registry-sync.py} ${registrySettings}";
          };
        };
        systemd.timers.herdr-registry-sync = lib.mkIf registryEnabled {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "15s";
            OnUnitInactiveSec = "10s";
          };
        };

        # The hermes-CLI recognition plugin (see MODULES.services.herdr.hermesIntegration's
        # option docs for WHY process-name detection cannot work under Nix - the venv exec
        # chain makes argv0 `python3.14`, never `hermes`). herdr's OWN installer writes
        # $HERMES_HOME/plugins/herdr-agent-state/{plugin.yaml,__init__.py} and ensures the
        # `plugins: enabled:` entry in $HERMES_HOME/config.yaml. Verified against the v0.9.5
        # source (src/integration/targets.rs install_hermes + env.rs hermes_dir):
        #   - the hermes config dir is $HERMES_HOME when set, else ~/.hermes - we set it
        #     explicitly to the hermes-agent module's ${stateDir}/.hermes;
        #   - it REFUSES to run unless config.yaml exists there, hence after/wants
        #     hermes-agent.service (the upstream activation writes config.yaml before the
        #     gateway starts, so once that unit is active the file is guaranteed);
        #   - it needs no other binary (writes files; the plugin itself calls back into
        #     `herdr pane report-agent-session` at CLI runtime, from the pane's PATH, where
        #     the herdr-server-hermes unit already carries /run/current-system/sw/bin).
        # The command is idempotent (assets rewritten, config entry ensured), and
        # sysinit-reactivation re-runs it on every switch - which is also the UPGRADE path:
        # a newer pinned herdr re-copies newer assets at the switch that carries it.
        # Runs as the service uid itself (no root anywhere near $HERMES_HOME); UMask 0077 +
        # NoNewPrivileges follow the herdrServerUnits doctrine. ReadWritePaths is redundant
        # (no ProtectSystem on this module's units) but states the one path the unit may
        # touch.
        systemd.services.herdr-hermes-integration = lib.mkIf cfg.hermesIntegration {
          description = "Install herdr's hermes integration plugin into $HERMES_HOME";
          after = ["systemd-tmpfiles-setup.service" "hermes-agent.service"];
          wants = ["hermes-agent.service"];
          wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = config.services.hermes-agent.user;
            Group = config.services.hermes-agent.group;
            Environment = "HERMES_HOME=${config.services.hermes-agent.stateDir}/.hermes";
            ReadWritePaths = [config.services.hermes-agent.stateDir];
            ExecStart = "${herdrPkg}/bin/herdr integration install hermes";
            NoNewPrivileges = true;
            UMask = "0077";
          };
        };

        # Binaries, plus (for the app) its .desktop entry and icon, which land in the system
        # profile's share/applications and so show up in the launcher (wofi reads exactly that
        # directory) with no further wiring. The != null guards are not the place a stale pin
        # gets reported - the assertions above do that - they are there so a null never reaches
        # environment.systemPackages, where it would fail as an opaque "not a derivation" type
        # error alongside (or instead of) the helpful message.
        environment.systemPackages =
          (lib.optionals (cfg.installCli && herdrPkg != null) [herdrPkg])
          ++ (lib.optionals (cfg.installCore && corePkg != null) [corePkg])
          ++ (lib.optionals (cfg.installApp && appPkg != null) [appPkg]);

        # The catalog fragment (exact SavedSshEndpoint JSON, deterministic ids) and the alias-
        # keyed known_hosts both machines ssh and any human `ssh herdr-<name>` read. Both are
        # world-readable: machine identity is public material (hostKeys doctrine); the PRIVATE
        # hub key never lands here (sops mount only).
        environment.etc."herdr/endpoints-managed.json".text = endpointsFragment + "\n";
        environment.etc."herdr/known-hosts".text =
          lib.concatStringsSep "\n"
          (lib.flatten (lib.mapAttrsToList machineKnownHosts resolvedMachines))
          + "\n";

        # Merge the declared catalog into every CLI user's endpoints.json, the same doctrine
        # as herdr-programs-merge below: user rows survive, declared (target+session) rows are
        # re-asserted, a hand-`machine add` of the same target+session is REPLACED by its
        # declared twin (same id everywhere is the point of the deterministic hash). Selection
        # and unknown top-level keys round-trip: the file is rewritten only when it actually
        # changes, so the client's 1s reload poll sees an atomic edit at most once per change
        # (herdr itself writes it atomically too; it is not locked - last writer wins per
        # field group, and herdr only ever rewrites ids it generated or the selection).
        # A corrupt user file is kept as <file>.herdr-nixos-backup, same as programs.json.
        # Forward-compat note: the rewrite round-trips the three keys the v1 schema has
        # (version, selected_profile, ssh) - if upstream's catalog ever grows top-level keys,
        # this merge drops them, and the file's own `version` field is where that would show.
        systemd.services.herdr-endpoints-merge = lib.mkIf (cfg.machines != {} || fleetMachines != {}) {
          description = "Merge declared herdr TUI machine catalog (MODULES.services.herdr)";
          after = ["local-fs.target" "systemd-tmpfiles-setup.service"];
          # sysinit-reactivation.target is restarted by switch-to-configuration on EVERY
          # activation (measured hp 2026-11-10: the 26.05 Rust switcher's own "start new
          # units" pass silently skipped both merge units after a deploy - enabled, dead,
          # no journal entry, while the same switch restarted sysinit-reactivation.target).
          # Attaching here makes every switch re-merge, which is also the correct semantic:
          # the fleet catalog changed => the switch that carries it re-asserts it.
          wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
          serviceConfig = {
            Type = "oneshot";
            # WITHOUT this, nixos-rebuild's unit starter (which does start+stop after the
            # switch) shuts the unit down right after it ran and a later `systemctl start`
            # re-executes it (programs-merge has re-run on every activation since 2026-11-09;
            # the first endpoints-merge version, without this flag, never started on its own
            # after a switch - measured hp 2026-11-10: enabled, dead, zero journal entries,
            # and `machine list` stayed []). The user file may hold secrets-ish scrollback
            # refs, but the script is an idempotent cmp-guarded rewrite, so re-runs are free.
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "herdr-endpoints-merge" ''
              set -eu
              ${lib.concatMapStringsSep "\n" (
                  name: let
                    ua = config.users.users.${name} or null;
                  in
                    lib.optionalString (ua != null && cfg.users.${name}.cli.enable) ''
                      # ${name}
                      dir="${ua.home}/.local/state/herdr/client"
                      target="$dir/endpoints.json"
                      mkdir -p "$dir"
                      chown ${name}:${ua.group} "$dir"
                      chmod 0700 "$dir"
                      tmp="$(mktemp)"
                      merge() {
                        ${pkgs.jq}/bin/jq -s '
                          (.[1].ssh) as $want
                          | (.[0] // {}) as $cur
                          | ($want | map(.id)) as $ids
                          | ($want | map(.target + " " + .session)) as $wt
                          | {version: 1,
                             selected_profile: ($cur.selected_profile // null),
                             ssh: ( (( $cur.ssh // [])
                                     | map(select(
                                         (((.id // "") as $i | ($ids | index($i)) | not)
                                          and (((.target // "") + " " + (.session // "")) as $t
                                              | ($wt | index($t)) | not))))
                                   ) + $want )}
                        ' "$1" /etc/herdr/endpoints-managed.json
                      }
                      if [ -s "$target" ] && ! ${pkgs.jq}/bin/jq -e . "$target" >/dev/null 2>&1; then
                        # Unparseable is not ours to interpret - keep it, start from the fragment.
                        cp -f "$target" "$target.herdr-nixos-backup"
                        cp /etc/herdr/endpoints-managed.json "$tmp"
                      elif [ -s "$target" ] && merge "$target" >"$tmp"; then
                        :
                      else
                        cp /etc/herdr/endpoints-managed.json "$tmp"
                      fi
                      if cmp -s "$tmp" "$target" 2>/dev/null; then
                        rm -f "$tmp"
                      else
                        install -m 0600 -o ${name} -g ${ua.group} "$tmp" "$target"
                      fi
                      rm -f "$tmp"
                    ''
                )
                (lib.attrNames managedUsers)}
            '';
          };
        };

        # The declared agent table. programs.json is app-owned (the user can edit
        # it, mods can too - the file watcher reloads it live), so it gets the
        # fleet's merge doctrine, not L+: the key name "match" is exactly what
        # serde reads (src/programs.rs Entry renames `also` to it on (de)serialize).
        environment.etc."herdr/programs-managed.json".text = lib.mkIf (cfg.agents != {}) (
          builtins.toJSON {
            programs =
              lib.mapAttrs (
                key: e:
                  {
                    inherit (e) name run tint;
                  }
                  // lib.optionalAttrs (e.icon != null) {inherit (e) icon;}
                  // lib.optionalAttrs (e.tile != null) {inherit (e) tile;}
                  // lib.optionalAttrs (e.color != null) {inherit (e) color;}
                  // lib.optionalAttrs (e.match != []) {match = e.match;}
              )
              cfg.agents;
          }
        );

        # Merge over every APP user's table (the menu belongs to the GUI; TUI-only
        # users have no programs.json and no menu). Only ~/.config/herdr-app is
        # touched - $HERDR_APP_HOME/XDG_CONFIG_HOME relocation is out of scope here
        # (this fleet runs plain XDG homes).
        systemd.services.herdr-programs-merge = lib.mkIf (cfg.agents != {}) {
          description = "Merge declared herdr-app programs.json (MODULES.services.herdr)";
          after = ["local-fs.target" "systemd-tmpfiles-setup.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "herdr-programs-merge" ''
              set -eu
              ${lib.concatMapStringsSep "\n" (
                  name: let
                    ua = config.users.users.${name} or null;
                  in
                    lib.optionalString (ua != null && cfg.users.${name}.app.enable) ''
                      # ${name}
                      dir="${ua.home}/.config/herdr-app"
                      target="$dir/programs.json"
                      mkdir -p "$dir"
                      chown ${name}:${ua.group} "$dir"
                      chmod 0700 "$dir"
                      tmp="$(mktemp)"
                      if [ -s "$target" ] && ! ${pkgs.jq}/bin/jq -e . "$target" >/dev/null 2>&1; then
                        # Unparseable is not ours to interpret - keep it, start from the fragment.
                        cp -f "$target" "$target.herdr-nixos-backup"
                        cp /etc/herdr/programs-managed.json "$tmp"
                      elif [ -s "$target" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" /etc/herdr/programs-managed.json >"$tmp"; then
                        :
                      else
                        cp /etc/herdr/programs-managed.json "$tmp"
                      fi
                      if cmp -s "$tmp" "$target" 2>/dev/null; then
                        rm -f "$tmp"
                      else
                        install -m 0600 -o ${name} -g ${ua.group} "$tmp" "$target"
                      fi
                      rm -f "$tmp"
                    ''
                )
                (lib.attrNames managedUsers)}
            '';
          };
        };
      }

      # The dynamic cli.service units: a separate option definition, because the
      # literal above dotted-binds systemd.services.herdr-*-merge (one attrset
      # literal may bind a leaf both whole and dotted only once).
      {systemd.services = herdrServerUnits;}
    ]
  );
}
