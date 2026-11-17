# `omp-deploy <user@host>`: install (or UPDATE) the fleet-pinned omp on any
# ssh-reachable Linux/macOS box (the owner's `omp-deploy baumit@10.50.1.178`) by
# doing the EXACT same thing as the copied curl one-liner (owner rule 2026-11-15:
# "omp-deploy should always do the exact same thing as installing via the curl
# command" - so this command has NO behavior the curl path lacks):
#
#   1. fetch the hub's served installer bytes (the funnel header-token endpoint;
#      the token rides a header, never a URL log line), and
#   2. pipe them into the target over ssh stdin: `ssh target sh -s`.
#
# Everything else - the per-device key, the version check, the config, the smoke
# test - is the installer script itself running ON the target, identical to what a
# box that curled the script does:
#   * key: the TARGET mints/adopts `omp-<its own hostname>` at the hub's mint
#     daemon with its own python3/curl (proven on the baumit-pi, which reaches the
#     funnel fine), and falls back to the script's baked key with a NOTE when the
#     mint is unreachable - exactly like a curl|sh box. The previous revision
#     minted CLIENT-side and injected the key through an OMPI_DEPLOY_* env
#     override: a second path (its own name normalization, a value hop through the
#     target's process list, a key minted from THIS box's view) that could drift
#     from the curl behavior. Dropped 2026-11-15; the installer lost its override
#     stage the same day, so no caller CAN deviate anymore (rule 2).
#   * version: the hub re-renders the script on every activation, so a fetch always
#     carries the CURRENT nix pin; on the target the script replaces the binary iff
#     its version differs and rewrites every config file from the nix render - a
#     re-run of either path IS the update.
#   * NixOS targets are refused BY THE INSTALLER ITSELF (declare
#     MODULES.services.omp instead); this command just passes that verdict through.
#
# The target needs no curl, no funnel reach and no token AT INSTALL TIME (only
# afterwards, for inference + its own mint attempt) - fetching here and streaming
# over stdin is the whole convenience this command adds over `curl | sh`.
{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.ompDeploy;

  # The gateway host (funnel + omp bootstrap enabled), derived through the flake's
  # own configs (the service-graph/amp cross-host doctrine).
  gatewayHosts =
    lib.filterAttrs (
      _: hc: (hc.config.MODULES.services.omp.bootstrap.enable or false) && (hc.config.MODULES.networking.traefik.funnel.enable or false)
    )
    nixosConfigurations;

  gatewayName =
    if gatewayHosts == {}
    then null
    else builtins.head (builtins.attrNames gatewayHosts);

  gatewayCfg = lib.optionalAttrs (gatewayName != null) gatewayHosts.${gatewayName}.config;
in {
  options.MODULES.services.ompDeploy = {
    enable = mkEnableOption ''
      the `omp-deploy <user@host>` command: fetch the hub's served omp installer
      and pipe it into the box over ssh - the curl one-liner, transported.
    '';

    installerUrl = mkOption {
      type = types.nullOr types.str;
      default =
        if gatewayName == null
        then null
        else gatewayCfg.MODULES.networking.traefik.funnel.urlOf "/install/omp.sh";
      defaultText = lib.literalExpression "the gateway host's funnel header-token installer URL";
      example = "https://hp.tail546fb.ts.net:8443/install/omp.sh";
      description = ''
        Fetched HERE (this host reaches the funnel), never on the target. The
        enrollment token travels as the X-Install-Token header (bootstrap-installers
        headerTokens), so no secret appears in any URL.
      '';
    };

    tokenSecret = mkOption {
      type = types.str;
      default = "paseo/enrollment_token";
      description = "sops key holding the installer's enrollment token (must equal the gateway host's MODULES.services.bootstrapInstallers.tokenSecret).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.installerUrl != null && gatewayName != null;
        message = "MODULES.services.ompDeploy: no gateway host (funnel + omp.bootstrap.enable) exists to derive the installer URL from - set installerUrl by hand.";
      }
    ];

    # Group-readable (wheel): the command runs fine as the interactive user OR root.
    sops.secrets.${cfg.tokenSecret} = {
      group = "wheel";
      mode = "0440";
    };

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "omp-deploy" ''
        # omp-deploy [-J <jump-spec>] <user@host | host>
        #   -J <jump>: ssh ProxyJump for targets this host cannot reach directly
        #       (the owner's pi: `omp-deploy -J root@hp baumit@10.50.1.178`).
        set -euo pipefail

        URL='${cfg.installerUrl}'
        JUMP=""
        TARGET=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -J) JUMP="''${2:-}"; shift 2 ;;
            -h|--help) echo "usage: omp-deploy [-J <jump>] <user@host>" >&2; exit 0 ;;
            *) TARGET="''${1#ssh }"; shift ;;
          esac
        done
        [ -n "$TARGET" ] || { echo "usage: omp-deploy [-J <jump>] <user@host>" >&2; exit 2; }

        SSHOPTS="-o BatchMode=yes -o ConnectTimeout=10"
        [ -n "$JUMP" ] && SSHOPTS="$SSHOPTS -J $JUMP"

        # ssh's own config resolves bare names (this fleet's sshClient Host blocks +
        # the user's ~/.ssh/config), so `omp-deploy pi` works wherever `ssh pi` does.
        echo "omp-deploy: fetching the hub installer (token in a header, never a URL)"
        SCRIPT="$(curl -fsSL -H "X-Install-Token: $(cat ${config.sops.secrets.${cfg.tokenSecret}.path})" "$URL")"

        echo "omp-deploy: piping it to ''${TARGET} over ssh - the box runs the EXACT curl|sh script"
        # sh -s over stdin: byte-identical to what `curl <url> | sh` executes on a
        # box that could reach the funnel itself. No env overrides by design - the
        # installer (and the target's own mint attempt) decides everything, so the
        # two paths can never drift.
        printf '%s\n' "$SCRIPT" | ssh $SSHOPTS -- "$TARGET" "sh -s"

        echo "omp-deploy: done. On the box: new shell (or source ~/.bashrc), then run 'omp'."
      '')
    ];
  };
}
