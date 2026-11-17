# Persistent loopback web tunnels from hp to the UNMANAGED lab machines the herdr hub
# already dials (the robots), surfaced on hp's tailnet zone as <subdomain>.<host zone>.
# The robot-side UltraTrainer doctrine (owner ask 2026-11-13, mirroring the datalab web
# harness in datalab-harness.nix): the app is SPAWNED, not started - a herdr menu row on
# the machine's own space runs ~/.local/bin/ultra-trainer, which attaches-or-starts a
# tmux session on the robot; the tunnel below only carries the UI out, hp:PORT ->
# robot:PORT, so https://ultra-trainer.r4uai01.hp answers the moment the harness is up
# and 502s until then. Spawning is the on-switch; the training itself keeps running in
# the robot's tmux across any pane/app disconnect.
#
# Why a root ssh -N and not a per-user forward: the dial identity is the hub's -
# the `Host herdr-*` aliases /etc/ssh/ssh_client already carries (User apapp, pinned
# /etc/herdr/known-hosts, and the Match-root exec rule that serves
# /run/secrets/herdr/hub_ssh_key only to uid 0). Reusing that alias duplicates no key,
# host-key or firewall fact (AGENTS.md Rule 2); the alias is a documented sshClient.
# blocks consumer (herdr.nix). Outbound on wt0 (netbird lab route) - no service-graph
# edge: the Suricata taps watch tailscale0 and the public loopback entry points, not the
# netbird wire (same scoping as the tuvpn/datalab tunnels, which dial TU over tun0).
#
# DNS/cert: a traefik.services entry whose KEY contains a dot (e.g.
# "ultra-trainer.r4uai01") already emits the dnsmasq address= for the full name and the
# Host() router - the zone is authoritative for everything under .hp, so no
# dns.aliases entry is needed. step-ca wildcards are label-perfect, so the module adds
# the one-level-deeper wildcard ("*.r4uai01.hp") to the CA allow-list itself.
#
# Robot-side manual step (unmanaged hosts; this comment + the tunnel entry are the
# registry, same doctrine as users/herdr-mobile.pub on apapp's authorized_keys;
# APPLIED on r4uai01 2026-11-13):
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv      # once per robot
#   cat > ~/.local/bin/ultra-trainer <<'EOF'
#   #!/bin/sh
#   # herdr menu row: attach-or-start the UltraTrainer web app in tmux
#   # (fleet tunnel: hp:<PORT> -> here:<PORT>, https://<subdomain>.hp on the tailnet)
#   # TERM pinned: hc panes advertise ghostty, this box's tmux needs a terminfo it has.
#   TERM=xterm-256color
#   export TERM
#   cd "$HOME/ultra-trainer" || exit 1
#   # UT_PORT is exported INSIDE the tmux command: r4uai01's .zshenv exports
#   # UT_PORT=8080 for every zsh, and the tmux pane (a login zsh) would re-apply it,
#   # silently moving the app off the port hp tunnels to. The pane command runs after
#   # .zshenv, so this wins (measured 2026-11-13).
#   exec tmux new -As ultra-trainer 'UT_PORT=<PORT>; export UT_PORT; exec ./run.sh'
#   EOF
#   chmod +x ~/.local/bin/ultra-trainer
# (.zshenv because the robots' zsh adds ~/.local/bin only for INTERACTIVE shells and the
# herdr core's own PATH lacks it entirely; .zshenv is sourced for every zsh mode. The
# programs.json row "UltraTrainer" (run: ultra-trainer) is already fleet-wide via
# MODULES.services.herdr.agents.)
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types literalExpression;
  cfg = config.MODULES.services.labWebTunnels;
  traefik = config.MODULES.networking.traefik;
in {
  options.MODULES.services.labWebTunnels = {
    enable = mkEnableOption ''
      persistent root loopback web tunnels to herdr-catalog lab machines, each published
      as a <subdomain>.<host zone> Traefik router with a step-ca cert (spelled out by
      the tunnel entry). The remote app is spawned on the machine itself (herdr menu),
      never started by these units.
    '';

    tunnels = mkOption {
      type = types.attrsOf (types.submodule (
        {name, ...}: {
          options.sshHost = mkOption {
            type = types.str;
            default = "herdr-${name}";
            example = "herdr-r4uai01";
            description = ''
              ssh destination: an alias already rendered into /etc/ssh/ssh_config by some
              owner module (herdr's catalog `Host herdr-*` blocks are the fleet's), with
              User, identity and pinned host keys all resolved by that alias. The default
              fits only when the tunnel attr name IS the machine name; when the attr
              keys the app instead ("ultra-trainer-r4uai01" - a machine may host several
              web UIs) spell this out ("herdr-r4uai01").
            '';
          };

          options.subdomain = mkOption {
            type = types.str;
            default = name;
            example = "ultra-trainer.r4uai01";
            description = ''
              Name under this host's zone the UI is published on (a dot is allowed and
              means one level DEEPER: "ultra-trainer.r4uai01" ->
              https://ultra-trainer.r4uai01.hp; the CA wildcard for the deeper level is
              added automatically).
            '';
          };

          options.port = mkOption {
            type = types.port;
            example = literalExpression "config.PORTS.ultraTrainerR4uai01";
            description = ''
              The SAME port on both sides (hp loopback bind == the app's bind on the
              machine; the robot-side launcher exports UT_PORT with this value). Named
              in PORTS, never inlined.
            '';
          };
        }
      ));
      default = {};
      example = literalExpression ''
        {
          "ultra-trainer-r4uai01" = {
            port = config.PORTS.ultraTrainerR4uai01;
            subdomain = "ultra-trainer.r4uai01";
          };
        }
      '';
      description = "name -> tunnel; the attr name keys the unit (lab-web-<name>) only.";
    };
  };

  config = mkIf (cfg.enable && cfg.tunnels != {}) {
    assertions = [
      {
        assertion = traefik.enable;
        message = "labWebTunnels publishes through Traefik (MODULES.networking.traefik.enable).";
      }
    ];

    # Bind-or-die forwards, re-dialing forever: a robot reboot, a netbird flap or the
    # hub key mount arriving late are all transient by design (same unit doctrine as
    # datalabHarness web tunnels: SuccessExitStatus=255 keeps a failed DIAL out of the
    # `failed` state so a switch can never be rolled back by a lab blip).
    systemd.services =
      lib.mapAttrs' (
        n: t:
          lib.nameValuePair "lab-web-${n}" {
            description = "Loopback web tunnel ${traefik.hostOf t.subdomain} -> ${t.sshHost}:${toString t.port}";
            wantedBy = ["multi-user.target"];
            after = ["network-online.target" "netbird.service" "sops-install-secrets.service"];
            wants = ["network-online.target"];
            unitConfig.StartLimitIntervalSec = 0;
            serviceConfig = {
              Type = "simple";
              ExecStart = "${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -L 127.0.0.1:${toString t.port}:localhost:${toString t.port} ${t.sshHost}";
              Restart = "always";
              RestartSec = "10s";
              SuccessExitStatus = "255";
            };
          }
      )
      cfg.tunnels;

    # hostOf on a dotted service key yields the deep name directly (dns.nix address= and
    # the router Host() both derive from it) - the whole publication is this one map.
    MODULES.networking.traefik.services =
      lib.mapAttrs' (
        _: t: lib.nameValuePair t.subdomain "127.0.0.1:${toString t.port}"
      )
      cfg.tunnels;

    # step-ca signs label-perfect wildcards only: every tunnel whose name hangs a level
    # below a nonzone label ("ultra-trainer.r4uai01") needs *.r4uai01.hp allowed.
    MODULES.networking.step-ca.extraAllowDns = lib.unique (
      lib.filter (w: w != null) (
        lib.mapAttrsToList (
          _: t: let
            parts = lib.splitString "." t.subdomain;
          in
            if lib.length parts > 1
            then "*.${lib.concatStringsSep "." (lib.tail parts)}.${traefik.domain}"
            else null
        )
        cfg.tunnels
      )
    );

    # No LIMITS rows: same doctrine as the datalab tunnels (idle ssh ~10M; the table is
    # fleet-static and rejects module-contributed rows by design).
  };
}
