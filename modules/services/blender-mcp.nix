# Blender MCP ("MCP for Blender", ahujasid/blender-mcp): registers the
# `mcp-for-blender` stdio server with EVERY coding-agent harness this repo
# configures (opencode, kilo, pi, omp, claude-code, cline, codex, amp), and keeps the
# matching Blender ADDON installed + enabled in the user's Blender so the
# server has something to talk to.
#
# Architecture (verified live on legion5 2026-11-06): the addon inside a
# RUNNING Blender owns a plain socket on localhost:PORT (it auto-starts when
# the GUI opens - the addon's scene default blendermcp_auto_start_server is
# true; _blendermcp_ensure_server_running skips only in background mode), and
# each harness spawns `mcp-for-blender`, which relays MCP tool calls over that
# socket. So the only system-managed pieces are (a) the server binary, (b) the
# per-harness config entries, and (c) the addon file + its enabled flag in each
# Blender userpref. No daemon here: the socket lives or dies with the Blender
# window, and every harness spawns its own server child.
#
# Feed design: each harness module grew a generic `mcp.servers` option (its
# OWN config dialect, merged at activation with user entries surviving); this
# module writes the `blender` entry through them instead of learning eight merge
# units. Entry shapes mirror what each app's own writer produces (each
# verified 2026-11-06, codex/amp 2026-11-09, against the pinned versions):
#   opencode/kilo  {type="local"; command=[...]; enabled=true;}  (OpenCode dialect)
#   pi             {command; args;}                               (~/.pi/agent/mcp.json)
#   omp            {type="stdio"; command; args;}                 (~/.omp/agent/mcp.json)
#   claude-code    {type="stdio"; command; args; env={};}         (~/.claude.json user scope)
#   cline          {command; args; alwaysAllow=[]; disabled=false;} (cline_mcp_settings.json)
#   codex          {command; args;}  ([mcp_servers.<name>], deny_unknown_fields)
#   amp            {command; args;}  (amp.mcpServers settings map)
#
# Server/package notes:
#   * The binary comes from packages/mcp-for-blender.nix (PyPI sdist; not in
#     nixpkgs), NOT `uvx` - store paths inline so no PATH/network at spawn
#     time, the playwright-mcp doctrine (modules/services/opencode.nix).
#   * PORTS.blenderMcp (modules/networking/ports.nix) is the single source for
#     the addon's socket port; the addon's own default is the same number and
#     its sidebar field must match if ever overridden.
#   * The addon file is COPIED (not symlinked) into ~/.config/blender/*/
#     scripts/addons/blender_mcp.py, mirroring the upstream installer: Blender
#     rewrites/saves addon state and the legacy addons dir expects real files.
#     Enabling it writes the userpref through a headless blender run AS THE
#     USER (addon_enable + save_userpref), and only where the user already has
#     ~/.config/blender - a home that never ran Blender stays untouched. A
#     running GUI Blender re-saves its userpref on exit, which can undo the
#     flag until the next activation; the addon's own UI checkbox is then the
#     user-side switch (upstream behavior, not a Nix promise).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    literalExpression
    types
    ;

  cfg = config.MODULES.services.blenderMcp;

  portStr = toString cfg.port;

  # stdio argv shared by every dialect (the flag is global to the CLI).
  serverArgs = ["--port" portStr];

  # The bundled addon inside the server's site-packages (one source: the
  # server's install-addon flow copies exactly this file). pkgs.python3 is
  # the interpreter callPackage injects into the package, so the spelling
  # matches its output by construction; sitePackages already carries the
  # `lib/` segment.
  bundledAddon = "${cfg.package}/${pkgs.python3.sitePackages}/blender_mcp/bundled/addon.py";

  # Per-dialect entry mirrors (see header for the verification record).
  opencodeEntry = {
    type = "local";
    command =
      [
        "${lib.getExe cfg.package}"
      ]
      ++ serverArgs;
    enabled = true;
  };
  stdioEntry = {
    type = "stdio";
    command = lib.getExe cfg.package;
    args = serverArgs;
  };
  piEntry = {
    command = lib.getExe cfg.package;
    args = serverArgs;
  };
  # cline's own writer emits no `type` key for stdio entries; mirror it.
  clineEntry = {
    command = lib.getExe cfg.package;
    args = serverArgs;
    env = {};
    alwaysAllow = [];
    disabled = false;
  };

  # Enabling the add-on in the prefs: a store-side script FILE, not a
  # --python-expr one-liner (quoting through runuser -c would hand Blender a
  # literal backslash-n). Idempotent: enable + save only when the module is
  # missing; the unit re-runs every activation.
  addonEnableScript = pkgs.writeText "blender-mcp-enable.py" ''
    import bpy

    mods = {a.module for a in bpy.context.preferences.addons}
    if "blender_mcp" not in mods:
        bpy.ops.preferences.addon_enable(module="blender_mcp")
        bpy.ops.wm.save_userpref()
        print("blender-mcp: add-on enabled in user prefs")
    else:
        print("blender-mcp: add-on already enabled")
  '';

  # Copy + (where prefs already exist) enable the addon, once per managed
  # user. runuser -l gives the headless blender the user's HOME env. The
  # addon FILE lands in every ~/.config/blender/<ver>/scripts/addons the user
  # has (the enable FLAG is only settable for blenderPackage's own prefs
  # version - each Blender major reads its own dir; upstream's installer has
  # the same limitation). `|| true` on the blender exec: a headless blender
  # that fails for ANY user-side reason must never fail the activation - the
  # server + harness entries work regardless; worst case the enable retries
  # next activation.
  addonScript = pkgs.writeShellScript "blender-mcp-addon" ''
    set -eu
    ${lib.concatMapStringsSep "\n" (
        u: let
          home = config.users.users.${u}.home;
          group = config.users.users.${u}.group;
        in ''
          # ${u}
          cfgroot="${home}/.config/blender"
          if [ -d "$cfgroot" ]; then
            for vdir in "$cfgroot"/*/; do
              [ -d "$vdir" ] || continue
              adir="$vdir/scripts/addons"
              mkdir -p "$adir"
              if ! cmp -s ${bundledAddon} "$adir/blender_mcp.py" 2>/dev/null; then
                install -m 0644 -o ${u} -g ${group} ${bundledAddon} "$adir/blender_mcp.py"
                rm -rf "$adir/__pycache__"
              fi
            done
            ${pkgs.util-linux}/bin/runuser -l ${u} -c '${
            lib.getExe cfg.blenderPackage
          } --background --python ${addonEnableScript}' || true
          fi
        ''
      )
      cfg.users}
  '';
in {
  options.MODULES.services.blenderMcp = {
    enable = mkEnableOption ''
      Blender MCP wiring: the mcp-for-blender stdio server registered with
      every configured coding-agent harness (opencode, kilo, pi, omp,
      claude-code, cline, codex, amp) plus the matching Blender add-on kept
      installed and enabled in the managed users' Blender prefs. Requires
      Blender installed on the host (users/akos.nix ships it); only hosts where
      Blender exists should enable this.
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/mcp-for-blender.nix {};
      defaultText = literalExpression "pkgs.callPackage ../../packages/mcp-for-blender.nix {}";
      description = "mcp-for-blender server package (also carries the bundled addon.py the install step copies).";
    };

    blenderPackage = mkOption {
      type = types.package;
      default = pkgs.blender;
      defaultText = literalExpression "pkgs.blender";
      description = ''
        Blender used for the headless add-on-enable step (its version decides
        which ~/.config/blender/<ver> prefs dir gets the enable flag). Only
        consulted when a managed user already has ~/.config/blender.
      '';
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.config/blender gets the add-on file + enable step. The harness config entries are global; this only drives the Blender-side install.";
    };

    port = mkOption {
      type = types.port;
      default = config.PORTS.blenderMcp;
      defaultText = literalExpression "config.PORTS.blenderMcp";
      description = "The addon socket port (both the server's --port and the single source of truth per the PORTS registry). A host overriding it must also set the same number in Blender's MCP sidebar.";
    };

    installAddon = mkOption {
      type = types.bool;
      default = true;
      description = "Run the per-activation add-on copy + enable step. Turn off to manage the Blender side entirely by hand (the harness wiring stays).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.installAddon || cfg.users != [];
        message = "MODULES.services.blenderMcp.users must name at least one user (or set installAddon = false).";
      }
      {
        assertion = builtins.all (u: config.users.users ? ${u}) cfg.users;
        message = "MODULES.services.blenderMcp.users names a user this system does not define.";
      }
      {
        # "enable where Blender exists" made declarative: the package the
        # enable step runs must actually be installed on this host (users/
        # akos.nix ships pkgs.blender). A host without Blender that still
        # wants the harness entries overrides blenderPackage or sets
        # installAddon = false.
        assertion = !cfg.installAddon || builtins.elem cfg.blenderPackage config.environment.systemPackages;
        message = ''
          MODULES.services.blenderMcp.installAddon needs Blender installed: ${cfg.blenderPackage} is not in
          environment.systemPackages. Install it, point blenderPackage at the package that IS
          installed, or set installAddon = false (harness entries only).
        '';
      }
    ];

    # Server on PATH for manual `mcp-for-blender` use (harness entries carry
    # the absolute store path regardless).
    environment.systemPackages = [cfg.package];

    # The eight harness feeds (each module merges these into the user's own
    # file; user-added servers survive, see the mcp.servers options).
    MODULES.services.opencode.mcp.servers = {blender = opencodeEntry;};
    MODULES.services.kilo.mcp.servers = {blender = opencodeEntry;};
    MODULES.services.pi.mcp.servers = {blender = piEntry;};
    MODULES.services.omp.mcp.servers = {blender = stdioEntry;};
    MODULES.services.claudeCode.mcp.servers = {
      blender = stdioEntry // {env = {};};
    };
    MODULES.services.cline.mcp.servers = {blender = clineEntry;};
    # codex's RawMcpServerConfig and amp's settings entries are both plain
    # command/args stdio records (deny_unknown_fields on codex's side, so no
    # `type` key) - the piEntry shape verbatim.
    MODULES.services.codex.mcp.servers = {blender = piEntry;};
    MODULES.services.amp.mcp.servers = {blender = piEntry;};

    systemd.services.blender-mcp-addon = mkIf cfg.installAddon {
      description = "Install + enable the MCP for Blender add-on (MODULES.services.blenderMcp)";
      after = ["local-fs.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = addonScript;
      };
    };
  };
}
