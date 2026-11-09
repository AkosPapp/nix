# /bin/bash, on demand.
#
# NixOS deliberately has no /bin/bash. Its activation symlinks exactly one
# thing there - /bin/sh, from environment.binsh (${pkgs.bashInteractive}/bin/sh
# by default; see nixos/modules/config/shells-environment.nix, which also does
# the `mkdir -p /bin; chmod 0755 /bin` that makes the directory exist and stay).
# That is right for the OS and fatal for anything that hard-codes the FHS path:
# such a caller fails at posix_spawn with ENOENT *before* its command runs, so
# every attempt errors identically no matter what it asked for. Measured on
# legion5 2026-11-08, where an agent's whole run_commands surface was dead this
# way while trying to evaluate modules/services/herdr.nix.
#
# A symlink, not a package: putting bash in environment.systemPackages lands it
# in a profile bin/ (a second bash on every PATH) and still leaves nothing at
# /bin/bash. tmpfiles' L+ re-points the link on every boot and every switch, so
# unlike a hand-made `ln -s` it cannot dangle after a bash bump. /bin is a real,
# persistent directory that nothing prunes, which is why the link survives both.
#
# The environment.systemPackages entry keeps the link's target rooted. /bin is
# not itself a GC root, so a bare symlink would leave bashInteractive held only
# by whatever else happens to reference it. It may well already be in
# environment.defaultPackages (I could not verify that from here), in which case
# this is redundant - kept deliberately, since the cost is a store path NixOS
# almost certainly ships anyway and the failure mode it guards against is a
# dangling /bin/bash exactly when an agent least expects one.
#
# Off by default; modules/services/cline.nix turns it on for the hosts that run
# the agent tool layer, and it is otherwise a one-line enable per host.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.system.binBash;
in {
  options.MODULES.system.binBash = {
    enable = mkEnableOption "a managed /bin/bash symlink for callers that hard-code the FHS path";

    package = mkOption {
      type = types.package;
      default = pkgs.bashInteractive;
      defaultText = lib.literalExpression "pkgs.bashInteractive";
      description = ''
        What /bin/bash points at. bashInteractive is the same package NixOS
        already resolves /bin/sh to (environment.binsh), so the two paths land
        on one executable and the link adds no second bash to the closure.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The d rule exists so the L+ never depends on /bin already being there:
    # tmpfiles skips a rule whose parent is missing, the failure mode
    # modules/services/paseo-machine.nix documents. Mode is `-` rather than
    # 0755 so we only create /bin when absent and never chmod a directory that
    # is NixOS' to own (its own activation already does `mkdir -p /bin; chmod
    # 0755 /bin`, so in practice this line is a no-op on every host).
    systemd.tmpfiles.rules = [
      "d /bin - - - -"
      "L+ /bin/bash - - - - ${cfg.package}/bin/bash"
    ];

    # Keeps the link's target GC-rooted (see the header).
    environment.systemPackages = [cfg.package];
  };
}
