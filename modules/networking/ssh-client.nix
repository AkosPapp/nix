# The SSH *client* system config, single-owner edition.
#
# NixOS ships no /etc/ssh/ssh_config (measured 2026-10-26 while wiring znapzend: the file
# simply does not exist unless a module creates it), and environment.etc."ssh/ssh_config"
# cannot be defined twice - the "attribute already defined" trap. Every module that needs
# the ssh CLIENT to behave differently for some Host alias (znapzend's replication
# identity, the herdr hub's per-machine identity) contributes a `Host`/`Match` block
# through MODULES.networking.sshClient.blocks; this module is the only writer of the
# file. Same doctrine as PORTS/LIMITS: one owner, others restate values.
#
# MODULES.networking.sshClient.hostKeys is the sibling fact table: a host's own PUBLIC SSH
# host keys as known_hosts lines keyed by the address peers dial it at (its tailnet IP).
# Public material, safe to commit (2026-11-03 cross-check doctrine, same as the old
# MODULES.networking.tuvpn.server.hostKeys it replaced - one owner now, read across the
# flake by the tuvpn toggle's pin file AND modules/services/herdr.nix's machine catalog).
{
  config,
  lib,
  ...
}: let
  cfg = config.MODULES.networking.sshClient;
in {
  options.MODULES.networking.sshClient = {
    blocks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = lib.literalExpression ''
        [ "Host znap-akos01\n  HostName akos01\n  StrictHostKeyChecking accept-new\n" ]
      '';
      description = ''
        Verbatim Host/Match blocks appended, in order, to /etc/ssh/ssh_config. Each block
        MUST stand on its own lines (no leading indentation surprises: ssh reads
        continuation-agnostic line-based config). The file is only written when at least
        one block exists.
      '';
    };

    hostKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = lib.literalExpression ''
        [ "100.92.36.52 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." ]
      '';
      description = ''
        This host's public SSH host keys as known_hosts lines, keyed by the address peers
        dial it at (its Tailscale IP). Set on EVERY host that has tailnet peers pinning it
        (tuvpn clients, the herdr machine catalog); consumers read it across the flake via
        nixosConfigurations, they never restate the key material. Regenerate with
        `ssh-keyscan <ip>` over the tailnet after any /etc/ssh/ssh_host_* change.
      '';
    };
  };

  config = lib.mkIf (cfg.blocks != []) {
    environment.etc."ssh/ssh_config".text =
      lib.concatMapStringsSep "\n" (b: lib.removeSuffix "\n" b) cfg.blocks
      + "\n";
  };
}
