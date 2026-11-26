# Playwright MCP ("@playwright/mcp", the official Playwright MCP server; the
# nixpkgs `playwright-mcp` package): registers a stdio server with the
# configured browser-capable harnesses (opencode, omp) so a session can drive
# a real Chromium-family browser - navigate, click, type, screenshot - in its
# own persistent automation profile, never attached to the user's daily-driver
# profile (logins made there survive restarts but stay out of the daily one).
#
# This block lived inside modules/services/opencode.nix as `mcp.playwright`
# until 2026-11-19, when the harnesses were consolidated (omp became the only
# interactive agent for akos) and it became a blender-mcp-style FEED: the
# module writes the `playwright` entry through each harness module's generic
# `mcp.servers` option, in that harness's own config dialect:
#   opencode  {type="local"; command=[...]; enabled=true;}  (OpenCode dialect;
#             {env:HOME} is expanded by opencode at config load, because
#             /etc/opencode.json is user-agnostic)
#   omp       {type="stdio"; command; args;}               (omp expands ${VAR}
#             placeholders in mcp.json at discovery - measured 2026-11-19 with
#             a probe stdio server echoing its argv: ${HOME} arrived expanded)
# Store paths inline, so no PATH or node/npx at spawn time - the doctrine
# mcp-for-blender.nix inherited from the original opencode implementation.
#
# The omp feed has a load-order precondition, and this module enforces it:
# while omp's native browser prelude is callable (browser.enabled, the
# default), omp QUIETLY DROPS any recognized browser-automation MCP server at
# config load - name `playwright`, the @playwright/mcp package pattern
# (docs/mcp-config.md). So enabling this sets MODULES.services.omp.browserNative
# = false, which ships `browser.enabled: false` in the PI_CONFIG_FILES overlay
# (the overlay layer outranks a user's own config.yml, so the drop-filter is
# off even if the user re-enabled the prelude locally). Disable this module to
# get the native headless tool back.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
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

  cfg = config.MODULES.services.playwrightMcp;

  # Shared playwright-mcp CLI flags; only the --user-data-dir value differs
  # per dialect (each harness's HOME-substitution spelling). --browser
  # chromium is the engine for ANY Chromium-based binary handed to
  # --executable-path (Brave here). --caps vision,pdf (0.0.83+): coordinates
  # on screenshots for vision-based clicking, and browser_pdf_save - the
  # capabilities that close the gap to ChatGPT's browser use (added with the
  # version bump 2026-11-20; the flags did not exist at 0.0.69).
  commonArgs = [
    "--browser"
    "chromium"
    "--executable-path"
    (lib.getExe cfg.browser)
    "--caps"
    "vision,pdf"
  ];

  dirArgs = homeExpr: ["--user-data-dir" "${homeExpr}/${cfg.userDataDir}"] ++ cfg.extraArgs;
in {
  options.MODULES.services.playwrightMcp = {
    enable = mkEnableOption ''
      the Playwright MCP server (drive a real browser from the agent): fed to
      every configured browser-capable harness (opencode, omp) through their
      mcp.servers options. Off by default: an agent with hands on a browser is
      a big capability, so each host opts in explicitly. On omp it also flips
      browser.enabled=false (the native prelude would drop this server).
    '';

    package = mkOption {
      type = types.package;
      default = pkgs-unstable.playwright-mcp;
      defaultText = literalExpression "pkgs-unstable.playwright-mcp";
      description = ''
        playwright-mcp package the harnesses spawn as the stdio MCP server.
        Bumped stable-0.0.69 -> unstable-0.0.83 on 2026-11-20 (the same pin
        hermes-desktop.nix chose for hp's HTTP server): 0.0.69 predates the
        --caps vision,pdf capability flags, so the agent could not click by
        coordinates from a screenshot or save a page as PDF - the two
        capabilities that put browser use on ChatGPT-desktop parity. Both
        nixpkgs pins verified substitutable; verified live on 0.0.83
        (stdio server + /mcp streamable HTTP + flag surface) before the bump.
      '';
    };

    browser = mkOption {
      type = types.package;
      default = pkgs.brave;
      defaultText = literalExpression "pkgs.brave";
      description = "Chromium-based browser Playwright launches, passed as --executable-path.";
    };

    userDataDir = mkOption {
      type = types.str;
      default = ".local/share/playwright-mcp/profile";
      description = ''
        Home-RELATIVE profile directory for the launched browser; the feed
        renders it under each dialect's HOME placeholder ({env:HOME} for
        opencode, ''${HOME} for omp - both expand at config load). One profile
        is shared ACROSS the harnesses this module feeds: Chromium locks its
        user-data-dir, so opencode and omp must not drive playwright at the
        same time (harmless since the 2026-11-19 consolidation, which left omp
        as the only enabled consumer; give a second concurrent harness its own
        value through an extraArgs --user-data-dir override or per-host option).
        Must be writable and must be set: without it playwright-mcp puts its
        default profile under $PLAYWRIGHT_BROWSERS_PATH, which the nixpkgs
        wrapper pins to the read-only store (measured on legion5 2026-10-27:
        first navigate failed "ENOENT ... mkdir /nix/store/...-playwright-browsers/
        mcp-chrome-for-testing-7799135").
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [
        "--headless"
        "--isolated"
      ];
      description = "Extra playwright-mcp CLI flags, appended verbatim to the rendered command in every dialect.";
    };

    requestTimeoutMs = mkOption {
      type = types.ints.positive;
      default = 120000;
      description = ''
        omp's per-server MCP request timeout for this entry. The client default
        is 30 s, and a navigate/screenshot on a slow page legitimately exceeds
        it; opencode has no equivalent knob (it manages its own MCP timeouts).
      '';
    };
  };

  config = mkIf cfg.enable {
    # The two harness feeds (each module merges these into the user's own
    # file; user-added servers survive, see the mcp.servers options).
    MODULES.services.opencode.mcp.servers = {
      playwright = {
        type = "local";
        command = [(lib.getExe cfg.package)] ++ commonArgs ++ (dirArgs "{env:HOME}");
        enabled = true;
      };
    };
    MODULES.services.omp.mcp.servers = {
      playwright = {
        type = "stdio";
        command = lib.getExe cfg.package;
        args = commonArgs ++ (dirArgs "\${HOME}");
        timeout = cfg.requestTimeoutMs;
      };
    };
    # Without this omp drops the entry above at load (see header); the option's
    # own default is true, so this module is the only thing that moves it.
    MODULES.services.omp.browserNative = false;
  };
}
