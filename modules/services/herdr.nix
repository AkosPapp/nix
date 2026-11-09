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
# Both servers are per-USER and deliberately NOT supervised by us. herdr-core spawns its own
# core and holder processes as *transient systemd user services* via systemd-run
# (crates/herdr-core/src/platform/systemd.rs), and its security doc says "Do not run core as
# root or as an administrator". A hand-written unit under systemd.services.* would run it as
# root and fight the program over the same processes - which is why the first draft of this
# module (a root Type=simple unit) was replaced on 2026-11-08. Both programs also start their
# own server on first use and keep it alive past the logout that spawned it.
#
# What we DO provide is the scaffolding a user manager cannot make for itself: linger (so
# /run/user/<uid> exists at boot - the directory the core puts its sockets in) and the
# private config/state directories. Look at what came up with `systemctl --user`.
#
# Multiple machines: enable the module per host and list the users who get state (legion5 is
# the only host with a normal account today, so hp and akos01 get the binaries and no per-user
# blocks). Machines join each other over SSH: `herdr machine add <host>` / `hc machine add
# <host>` - which is exactly why the binaries are installed on the headless servers too: an
# agent in an hp terminal keeps running there after you disconnect.
#
# No firewall port and no SERVICE_GRAPH edge: every socket here is a UNIX socket under
# /run/user/<uid>, and the cross-machine path is plain user-initiated SSH to sshd, which is
# already open on every host via MODULES.networking.sshd and is not a service-uid flow the
# jail or the Suricata tap sees.
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
      })
    else null;

  # Users whose herdr state we lay out. The TUI and the app are two different programs, so
  # each user picks them independently (userDirs / userConfigSeeds branch on cli.enable and
  # app.enable); a user with both gets both, and the two servers stay separate - agents
  # started in the TUI do not appear in the app and vice versa, upstream's own FAQ.
  # Enabling either implies linger, which is why the linger map keys off this, not the
  # narrower sets.
  managedUsers = lib.filterAttrs (_: u: u.enable) cfg.users;

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
        (dir "${ua.home}/.local")
        (dir "${ua.home}/.local/state")
        # Its server's session state; separate from the core's, on purpose (see the header).
        (dir "${ua.home}/.local/state/herdr")
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

  # Minimal TOML emitter. Both herdr config files are TOML-only, and I could not confirm a
  # TOML generator exists at this flake's nixpkgs pins (the pinned lib/generators.nix came
  # back truncated mid-list and noogle had no entry for it), so the module carries its own
  # instead of depending on an attribute that might not resolve - and instead of writing
  # JSON, which neither program can parse.
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
          The TUI starts its own server; nothing here starts it for it.
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
  };

  config = mkIf cfg.enable {
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
      ];

    # Linger for every managed user. Neither server depends on us to start it, but both
    # need the user manager to exist at boot: herdr-core puts its client socket under
    # /run/user/<uid>/herdr-core/ and, with no user manager, falls back to the state dir and
    # warns "no systemd user manager here: the core ends with whatever started it" - i.e.
    # every agent dies on logout. Enabling a user's herdr state therefore always enables
    # their linger.
    users.users = lib.mapAttrs (_: _: {linger = true;}) managedUsers;

    # The per-user directories and config seeds. Deferred into this option's *value* for
    # the usual reason: computing them needs the merged cfg.users, and reading cfg.users at
    # the module spine (in the top-level let) while this module still supplies its own
    # config closes that into infinite recursion. Same shape as
    # modules/services/paseo-machine.nix.
    systemd.tmpfiles.rules =
      builtins.concatLists (map userDirs (lib.attrNames managedUsers))
      ++ builtins.concatLists (map userConfigSeeds (lib.attrNames managedUsers));

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
  };
}
