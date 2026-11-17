# "datalab-harness": run coding agents on the TU cluster FROM hp, and let the TU-hosted
# reaper do the cleanup it exists for.
#
# The problem (user 2026-11-11): datalab kills all of alexander.lampalzer's processes
# whenever no ssh connection is active - so a plain `ssh datalab pi` dies with the phone
# disconnecting - yet the hp->datalab connection must NOT outlive the agent either (TU
# caps concurrent sessions, and a keepalive that never quits is just a squat). Both
# constraints are satisfied by binding the connection's lifetime to the harness':
#
#   hp's herdr-CORE (the app's backend, MODULES.services.herdr): ONE NAMED TERMINAL per
#   harness, dl-<name>, whose program is
#     ssh -F <pinned config> -t datalab 'exec tmux new -As harness-<name> <agent>'
#
#   * agent exits / is killed ON DATALAB -> its remote tmux session ends -> the hp ssh
#     ends -> the dl-<name> terminal FINISHES (its history stays scrollable in the app
#     until stop/rm sweeps it). No lingering connection; the reaper finds nothing of
#     ours. ("when I kill the harness the ssh session should quit with it" - `hc kill`
#     signals the ssh itself.)
#   * phone disconnects -> the core and its holder are systemd user services with
#     linger, so they survive logout (measured 2026-11-11: root's core up for days) ->
#     the ssh, the remote tmux and the agent keep running; `datalab-harness <name>` or
#     `hc attach dl-<name>` re-attaches from anywhere, and the app's terminal list
#     already shows dl-* beside every other terminal. This hop is the ONLY one the
#     reaper can see, and hp holds it open for exactly as long as a harness lives - the
#     TU VPN on hp (MODULES.networking.tuvpn) carries it.
#   * hp reboots or tun0 drops -> datalab sees the connection die -> the reaper does its
#     intended job. That is accepted, not hidden: nothing installed on datalab may
#     outlive sessions (user constraint), so no remote daemon, only ssh + the tmux that
#     ships with the cluster.
#
# Why an hc terminal - and not the hp-side tmux window of the first cut (2026-11-11
# morning): the user drives hp through herdr, so "open the harness" must land in the
# SAME UI they already look at, not a parallel tmux session invisible to the app.
# `hc run --bg --no-parent` keeps tmux's window-dies-with-its-command lifecycle (no
# Restart-policy gymnastics distinguishing "agent finished" from "link flapped"), the
# terminal NAME doubles as the dedupe key (a live dl-<name> is re-attached, never a
# second ssh squatting a TU slot), and dl-<name>'s finish-with-ssh is what frees the
# slot on kill. Each harness still keeps its own REMOTE tmux session (harness-pi, ...)
# so the agent survives an hp-side ssh flap as long as any connection to datalab lives.
# A harness with cmd "" (e.g. `shell`) skips the agent AND the remote tmux: a bare
# `ssh -t datalab` login shell, dying with its dl-shell terminal - interactive access
# to the cluster without starting anything, reaper-safe the same way.
#
# Identity: a dedicated keypair per doctrine - private half sops
# `harness/datalab_ssh_key_b64` (base64 like znapzend/ssh_key_b64), decoded to
# /etc/ssh/datalab/id_ed25519 0400 root (0440 root:<terminalAccess.user> when the
# terminal account below needs it); public half users/datalab-hp.pub, enrolled only
# in datalab's ~/.ssh/authorized_keys (2026-11-11). Revoking the harness does not touch
# any login identity, and the laptop/phone keys never land on hp for this purpose.
#
# terminalAccess adds hp's THIRD terminal account (after root and hermes - same shape,
# hermes-agent.nix sshAccess + herdr cli.service doctrine): a service user whose LOGIN
# SHELL is a wrapper that immediately execs the pinned `ssh -t datalab-harness` (with no
# remote command: a bare shell). The herdr core still runs entirely on hp and never
# learns anything crossed a network - its pane processes just happen to be ssh - so the
# user gets a "datalab machine" whose every new terminal is a TU keepalive: killing the
# terminal kills the ssh kills the datalab session (slot freed with the last one), while
# phone/laptop disconnects cannot (the server is the systemd unit, linger-less like
# hermes). Commands handed to the account over ssh (`sshd $SHELL -c '...'`: the hub's
# herdr bootstrap, scp, one-off su -c) pass through to bash UNWRAPPED - only interactive
# logins exec the ssh. The phone reaches the same account twice because its ssh
# client keys saved hosts by hostname: datalab@hp AND datalab@datalab.hp (a
# MODULES.networking.dns.aliases entry pointing at the same tailnet IP; one sshd, no
# extra ssh config - hosts/hp wires it 2026-11-11).
# The ssh invocation uses -F with a self-contained config (NOT a contribution to
# MODULES.networking.sshClient.blocks): nothing here must be reachable by accident from
# a plain `ssh cluster.datalab...` on hp, and -F also stops the global config's
# tailscale routing from shadowing the TU-routed hostname. Host keys are pinned from the
# laptop's cross-checked TOFU set (StrictHostKeyChecking yes, no accept-new: a public
# cluster box must fail loud at the pin, never re-TOFU after a network MITM).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types literalExpression;
  cfg = config.MODULES.services.datalabHarness;

  keyDir = "/etc/ssh/datalab";
  keyPath = "${keyDir}/id_ed25519";

  # The ssh client config -F reads. ServerAlive: a silently dead tun0 (VPN drop without
  # TCP FIN) must kill the window within ~3min so tmux reflects reality and the remote
  # side can reap, instead of a zombie connection that "keeps the slot" forever.
  # AddressFamily inet: TU's DNS also answers AAAA for the cluster, and hp's tunnel is
  # IPv4-only (measured 2026-11-11: `ip route get` on the v6 address stays on the WAN
  # default) - a v6 attempt just fails over slowly.
  sshConfig = pkgs.writeText "datalab-harness-ssh_config" ''
    Host datalab-harness
      HostName ${cfg.host}
      User ${cfg.user}
      IdentityFile ${keyPath}
      IdentitiesOnly yes
      UserKnownHostsFile ${keyDir}/known_hosts
      StrictHostKeyChecking yes
      ConnectTimeout 10
      # datalab's sshd is pre-ML-KEM: the client prints a 4-line "store now, decrypt
      # later" NOTICE on EVERY connection (verified), which would pollute `status` and
      # every rsh. ERROR keeps real errors visible.
      LogLevel ERROR
      ServerAliveInterval 60
      ServerAliveCountMax 3
      ${lib.optionalString cfg.forwardAgent ''
      # owner ask 2026-11-13: relay the SSH agent through the proxy so git/ssh
      # inside a `datalab@datalab.hp` pane authenticates with the LAPTOP's keys -
      # no private key ever lands on the TU cluster (its authorized_keys stays as
      # enrolled). Only panes from a direct interactive ssh reach an agent: the
      # login shell's exec inherits SSH_AUTH_SOCK, while systemd-spawned paths
      # (the menu launchers, hc terminals, the ssh -N web tunnels, rsh) have no
      # agent in their environment and ForwardAgent silently no-ops there. The
      # exposure this accepts: while such a pane lives, the cluster's root could
      # use the forwarded keys (classic -A risk, owner's call). It does NOT
      # weaken audit #8's agentAuth=false - that option is about AUTHENTICATING
      # INTO hp with an agent; nothing here changes hp's sshd or PAM.
      ForwardAgent yes
    ''}
    Host *
      AddressFamily inet
  '';

  # name -> the REMOTE command string the pinned ssh runs (its own nested quote for the
  # remote tmux's shell word). Kept per-name so runtime never assembles quotes: the
  # literal lands in the wrapper's case arms and is handed to ssh as ONE argv element
  # (word-splitting-safe under set -u, no eval anywhere). A harness with cmd "" gets an
  # empty arm: ssh with no remote command = plain login shell, no remote tmux, so the
  # shell (and the TU session) dies exactly when its dl-shell terminal does.
  # A harness that carries a `port` is a WEB-UI harness (UltraTrainer): its remote cmd
  # gains `<portEnv>=<port>; export <portEnv>` so the app binds the head-side END of the
  # hp loopback tunnel, and the same number (PORTS.ultraTrainer) names both sides so one
  # registry entry describes the app's port and the forward's port. The `VAR=x; export
  # VAR; <cmd>` form (not the `VAR=x <cmd>` prefix): a prefix assignment dies on the next
  # word, and these cmds start with `cd`, a special builtin that would swallow it.
  harnessCmd = hc:
    if hc.port == null
    then hc.cmd
    else "${hc.portEnv}=${toString hc.port}; export ${hc.portEnv}; ${hc.cmd}";

  # name -> harness whose cmd carries a web port; these get a persistent loopback tunnel
  # + a Traefik subdomain under `datalab.hp` (see the web-tunnel block in the config).
  webHarnesses = lib.filterAttrs (_: hc: hc.port != null) cfg.harness;

  remoteCmdFor = name: cmd: "exec tmux new -As harness-${name} '${lib.replaceStrings ["'"] ["'\\''"] cmd}'";

  # Nix-time single-quote escape for embedding strings into the wrapper's quoted arms.
  sq = s: lib.replaceStrings ["'"] ["'\\''"] s;

  arms =
    lib.concatStringsSep "\n        "
    (
      lib.mapAttrsToList (
        n: c:
          if c.cmd == ""
          then "${n}) printf '' ;;"
          else "${n}) printf '%s\n' '${sq (remoteCmdFor n (harnessCmd c))}' ;;"
      )
      cfg.harness
    );

  namesAlt = lib.concatStringsSep "|" (builtins.attrNames cfg.harness);

  # The terminal account's login shell (terminalAccess). Its ONLY job is the
  # interactive branch: a pty with no command means "the human wants datalab", so exec
  # the pinned ssh - no remote command (bare login shell), no hp-side keepalive of its
  # own: the ssh IS the pane's foreground program, so closing/killing the terminal ends
  # the TU session with it, while the linger-less herdr server (systemd unit) keeps the
  # panes alive across phone disconnects. EVERYTHING machine-driven must NOT reach that
  # branch: sshd runs `$SHELL -c '<bootstrap>'` for the hub's herdr bridge, and scp/sftp/
  # one-off su commands ride the same path - those pass through to bash verbatim, which
  # is what keeps datalab@hp a normal command-executing account (same reasoning as
  # hermes-agent.nix forcing a real bash: a blanket nologin/exec would break the
  # bootstrap itself). Non-tty stdin without -c (a piped script) also runs as bash.
  paneShell = pkgs.writeShellScriptBin "datalab-terminal-shell" ''
    if [ "''${1:-}" = "-c" ]; then exec ${pkgs.bash}/bin/bash "$@"; fi
    if [ -t 0 ]; then
      # TERM pinned: a systemd-spawned herdr server gives panes TERM=xterm-256color,
      # but a direct ssh (mosh, phone) inherits the CLIENT's TERM - and datalab has no
      # terminfo for exotic ones (the ghostty trap the harness wrapper documents). The
      # variable form (not ssh's SetEnv, which sshd must enable) keeps the -c passthrough
      # branch untouched: this exec is the interactive branch only. (`VAR=x exec cmd` is
      # undefined-behavior territory in POSIX shells - the assignment may die with the
      # builtin - so export first, then exec.)
      TERM=xterm-256color
      export TERM
      exec ${pkgs.openssh}/bin/ssh -F ${sshConfig} -t datalab-harness
    fi
    exec ${pkgs.bash}/bin/bash "$@"
  '';

  # Per-harness launchers for the herdr desktop app's AGENT MENU, and shims of the
  # same sessions under the agent's own name on the terminal account's PATH.
  #
  # Why (measured on the laptop's app against the datalab machine 2026-11-11): the
  # app's menu probes `command -v <entry.run[0]>` and execs that argv as the pane
  # program ON THE MACHINE HOSTING THE SPACE'S CORE - never through the account's
  # login shell. On the datalab space that machine is hp running as datalab, so
  # "OpenCode" launched /run/current-system/sw/bin/opencode *on hp* (hp's own
  # OPENCODE_CONFIG=/etc/opencode.json, and the gateway key mounts are
  # secretOwner=root 0400 -> "Authentication Required" with a plausible model list),
  # while Pi/Claude/Codex showed "not installed" - hp's PATH, not the laptop's.
  # Upstream's built-in table (extracted from herdr-app 0.1.10's binary) keys them
  # "pi"/"opencode" with run ["pi"]/["opencode"], and the probe runs with the core's
  # PATH - which leads with /etc/profiles/per-user/<user>/bin (verified from
  # /proc/<datalab core>/environ and the herdr-server unit env on hp). So the shim
  # set is per-account: in the datalab space `pi` and `opencode` resolve to the
  # cluster launchers below; on the laptop (akos's profile) they stay the local
  # agents. No programs.json entry needed anywhere - the menu's keys are stock.
  agentLauncher = name: hc:
    pkgs.writeShellScriptBin "datalab-${name}" ''
      # The pane becomes the TU keepalive: pane dies -> ssh dies -> the datalab
      # session ends (the reaper frees the slot; a harness-<name> tmux left by a dead
      # connection dies server-side too - nothing we install outlives sessions).
      # Re-opening the same harness re-attaches the same remote tmux (`-A`), exactly
      # like the hc-terminal path in the wrapper.
      #
      # TERM pinned for the same reason the paneShell and the wrapper's hc run do:
      # the spawning client's TERM (ghostty from hc, dumb from a detached core) has
      # no terminfo on datalab and tmux dies with "open terminal failed".
      TERM=xterm-256color
      export TERM
      # Arguments are NOT threaded into the remote tmux command: the tmux session
      # name is the identity of the harness (one attached agent, re-attached by
      # name), so a second launch with different flags would silently join the
      # FIRST one's agent. Say so instead of pretending.
      if [ "$#" -gt 0 ]; then
        echo "datalab-${name}: opens the attached cluster session (${hc.cmd}); arguments ignored" >&2
      fi
      exec ${pkgs.openssh}/bin/ssh -F ${sshConfig} -t datalab-harness ${
        lib.escapeShellArg (remoteCmdFor name (harnessCmd hc))
      }
    '';

  # cmd "" harnesses (bare `shell`) get NO launcher and NO shim: their name would
  # shadow nothing useful and the paneShell already makes every bare terminal of
  # the account a cluster login.
  agentHarnesses = lib.filterAttrs (_: hc: hc.cmd != "") cfg.harness;
  agentLaunchers = lib.mapAttrs' (n: hc: lib.nameValuePair n (agentLauncher n hc)) agentHarnesses;

  # The account-PATH shim: named EXACTLY as the built-in table probes it, so the
  # app's stock "Pi"/"OpenCode" rows ARE the cluster sessions in this account's
  # spaces. Args forward to the launcher (which warns that the named cluster
  # session is re-attached, not re-launched - see its comment).
  agentShim = name:
    pkgs.writeShellScriptBin name ''
      exec ${agentLaunchers.${name}}/bin/datalab-${name} "$@"
    '';

  wrapper = pkgs.writeShellScriptBin "datalab-harness" ''
    set -eu
    JQ="${pkgs.jq}/bin/jq"
    SSH="${pkgs.openssh}/bin/ssh"
    # hc comes from MODULES.services.herdr (pkgs-unstable.herdr-core); resolved at
    # runtime, not baked, so a host whose pin lacks herdr-core gets the assertion's
    # advice on switch AND a live PATH here can never point at a stale store path.
    if ! HC="$(command -v hc 2>/dev/null)"; then
      echo "datalab-harness: hc (herdr-core) not on PATH - enable MODULES.services.herdr" >&2
      exit 3
    fi
    KNOWN="${lib.concatStringsSep " " (builtins.attrNames cfg.harness)}"
    # harness_cmd NAME -> the remote command on stdout (EMPTY for a bare-shell harness),
    # rc=1 for an unknown name.
    harness_cmd() {
      case "$1" in
        ${arms}
        *) return 1 ;;
      esac
    }
    rsh() { $SSH -F ${sshConfig} -o BatchMode=yes -o ConnectTimeout=10 datalab-harness "$@"; }
    # A live dl-* terminal is the dedupe key: never a second ssh squatting a TU slot.
    live() { $HC ls --json 2>/dev/null | $JQ -e --arg n "$1" '.terminals[]? | select(.name == $n and .state == "live")' >/dev/null 2>&1; }
    dl_names() { $HC ls --all --json 2>/dev/null | $JQ -r '.terminals[]? | select((.name // "") | startswith("dl-")) | "  \(.name)  \(.state)  \(.address)"' || true; }

    case "''${1:-}" in
      stop)
        NAME="''${2:-}"
        if [ -z "$NAME" ]; then echo "usage: datalab-harness stop <$namesAlt>" >&2; exit 2; fi
        # Kill REMOTE first (that ends the agent, the ssh follows); kill/rm then sweep
        # the terminal record so a finished dl-* does not linger in the app's list.
        rsh "tmux kill-session -t harness-$NAME" 2>/dev/null || true
        $HC kill "dl-$NAME" >/dev/null 2>&1 || true
        $HC rm "dl-$NAME" >/dev/null 2>&1 || true
        echo "stopped $NAME"
        exit 0 ;;
      status)
        echo "-- hp core terminals:"
        OUT="$(dl_names)"
        if [ -n "$OUT" ]; then printf '%s\n' "$OUT"; else echo "  (none)"; fi
        echo "-- datalab harness sessions:"
        rsh "tmux ls" 2>&1 | sed 's/^/  /' || true
        exit 0 ;;
      "")
        # Bare call: the universal reconnect - one live harness goes straight in.
        LIVE="$($HC ls --json 2>/dev/null | $JQ -r '.terminals[]? | select((.name // "") | startswith("dl-") and .state == "live") | .name' || true)"
        N="$(printf '%s\n' "$LIVE" | grep -c . || true)"
        if [ "$N" -eq 1 ]; then
          $HC attach "$LIVE" || echo "already running - open '$LIVE' in the app, or from a core terminal: hc attach $LIVE"
        elif [ "$N" -eq 0 ]; then echo "no dl-* harness running; datalab-harness <$namesAlt>"
        else echo "several live - pick one (hc attach <name>):"; printf '%s\n' "$LIVE"; fi
        exit 0 ;;
      *)
        NAME="$1"
        T="dl-$NAME"
        CMD="$(harness_cmd "$NAME")" || { echo "unknown harness '$NAME' (known: $KNOWN)" >&2; exit 2; }
        if ! live "$T"; then
          # Sweep a finished record before re-dialling so the app shows one tile, not a
          # graveyard of exits.
          $HC rm "$T" >/dev/null 2>&1 || true
          # "$CMD" as ONE argv element: ssh must receive the whole remote command as a
          # single argument (hc passes its argv to ssh verbatim - splitting it here would
          # survive ssh's space-join by luck only). Empty CMD (bare-shell harness) ->
          # ssh with no remote command = login shell.
          # env TERM=xterm-256color: hc's pty advertises its own identity (TERM=ghostty,
          # measured) and datalab has no ghostty terminfo - the remote tmux died with
          # "open terminal failed: terminal does not support clear" (2026-11-11). The
          # old tmux-window wrapper never hit this because tmux sets TERM=screen-*.
          # Overriding at the ssh process fixes pty-req for BOTH branches (agent and
          # bare shell), so vim/less on datalab also resolve.
          if [ -n "$CMD" ]; then
            $HC run --bg --no-parent --name "$T" -- env TERM=xterm-256color $SSH -F ${sshConfig} -t datalab-harness "$CMD" >/dev/null
          else
            $HC run --bg --no-parent --name "$T" -- env TERM=xterm-256color $SSH -F ${sshConfig} -t datalab-harness >/dev/null
          fi
        fi
        # Attach only from a real terminal, and never DIE on attach: headless callers
        # (scripts, this ssh) and the app already see the terminal in the core's list;
        # hc attach from a NON-core terminal errors, which is a hint, not a failure.
        if [ -t 1 ]; then
          $HC attach "$T" || echo "$T running - open it in the app, or from a core terminal: hc attach $T"
        else
          echo "$T running: hc attach $T (or datalab-harness $NAME from a terminal)"
        fi
        ;;
    esac
  '';
in {
  options.MODULES.services.datalabHarness = {
    enable = mkEnableOption "hp-hosted, harness-lived ssh sessions to the TU datalab cluster (datalab-harness wrapper)";

    user = mkOption {
      type = types.str;
      example = "alexander.lampalzer";
      description = "datalab account the harness runs as (its ~/.ssh/authorized_keys must carry users/datalab-hp.pub).";
    };

    host = mkOption {
      type = types.str;
      default = "cluster.datalab.tuwien.ac.at";
      description = "datalab sshd address; resolution is irrelevant to liveness (public DNS answers even when the TU route is down - the ssh retry/keepalive is the real signal).";
    };

    keySecret = mkOption {
      type = types.str;
      default = "harness/datalab_ssh_key_b64";
      description = "sops key holding the base64 of the dedicated harness private key (public half: users/datalab-hp.pub).";
    };

    forwardAgent = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Relay the caller's ssh-agent through the hop into the cluster (datalab's
        sshConfig gains `ForwardAgent yes`), so git/ssh inside a proxied pane
        authenticates with the operator's laptop keys - no private key lands on the
        cluster. True by default (owner ask 2026-11-13); the accepted exposure is the
        classic -A one: while a pane lives, the cluster's root could use the agent.
        Independent of audit #8's sshd.agentAuth (which is about authenticating INTO
        hp and stays false).
      '';
    };

    knownHosts = mkOption {
      type = types.lines;
      example = literalExpression ''"cluster.datalab.tuwien.ac.at ssh-ed25519 AAAA..."'';
      description = "known_hosts lines pinned for `host` (public material; fail-loud pin, never accept-new).";
    };

    harness = mkOption {
      type = types.attrsOf (types.submodule (
        {name, ...}: {
          options.cmd = mkOption {
            type = types.str;
            default = name;
            example = "";
            description = ''
              Command the remote tmux session runs on datalab (PATH as resolved by a
              plain non-login ssh command - verified to include ~/.local/bin and
              ~/.opencode/bin 2026-11-11). The empty string starts NO agent and NO
              remote tmux: the ssh lands in a plain login shell instead, which dies
              with its dl-* terminal exactly like an agent does. A NON-empty cmd
              also builds the app-menu pair for this harness: a `datalab-<name>`
              launcher on the system PATH and (terminalAccess) a `<name>` shim on
              the account's profile PATH, so the herdr app's stock Pi/OpenCode menu
              rows open the cluster agent in the account's spaces - see
              agentLauncher's comment for the measured launch semantics.
            '';
          };

          options.port = mkOption {
            type = types.nullOr types.port;
            default = null;
            example = literalExpression "config.PORTS.ultraTrainer";
            description = ''
              Set for a WEB-UI harness: the port the app listens on at the CLUSTER
              head. It turns the harness into three things at once - the remote cmd
              gains a `<portEnv>=<port>` export (see portEnv), hp runs a persistent
              loopback ssh tunnel `hp:<port> -> head:<port>` (so the app is reachable
              without the human opening a browser-side -L forward), and Traefik gets
              `<webSubdomain>.datalab.hp` pointing at it. One number for both ends,
              from PORTS (AGENTS.md: no hardcoded ports).
            '';
          };

          options.portEnv = mkOption {
            type = types.str;
            default = "PORT";
            example = "UT_PORT";
            description = "Name of the environment variable `port` is exported as for this harness's app.";
          };

          options.webSubdomain = mkOption {
            type = types.str;
            default = name;
            example = "ultra-trainer";
            description = ''
              Subdomain UNDER `datalab.hp` (the zone the `datalab` DNS alias already
              owns: dnsmasq's address= record matches the whole subtree) that the web
              tunnel is published on. Only read when `port` is set.
            '';
          };
        }
      ));
      default = {};
      example = {
        pi = {};
        opencode.cmd = "opencode";
        shell.cmd = "";
        ultra-trainer = {
          cmd = "cd ~/ultra-trainer && ./run.sh";
          portEnv = "UT_PORT";
          port = 8146;
        };
      };
      description = ''
        Harnesses the wrapper can start; one herdr-core terminal (named dl-<name>) and
        one remote tmux session each. Names must match hc's terminal-name charset
        (a-z 0-9 - _, <= 29 chars so the dl- prefix fits hc's 32-byte cap).
      '';
    };

    terminalAccess = {
      enable = mkEnableOption ''
        a dedicated hp service account (name `user`, default "datalab") whose interactive
        logins - ssh, mosh, and every pane of its herdr TUI server (wire it via
        MODULES.services.herdr users.<name> + a machines row, like hp's hermes) - exec the
        pinned `ssh -t datalab-harness` straight onto the cluster: the terminal IS the TU
        keepalive, and killing it frees the session slot. Machine-driven ssh commands
        (-c, scp, sftp) run real bash on hp instead, so the account stays normal for the
        hub's herdr bootstrap
      '';

      user = mkOption {
        type = types.str;
        default = "datalab";
        description = "hp account name to create (its sshd keys are the terminalAccess trust set).";
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [];
        example = literalExpression ''
          [
            (lib.removeSuffix "\\n" (builtins.readFile ../../users/herdr-hub.pub))
            (lib.removeSuffix "\\n" (builtins.readFile ../../users/herdr-mobile.pub))
          ]
        '';
        description = ''
          Public keys the terminal account authenticates with (rendered to
          /etc/ssh/authorized_keys.d/<user>, the root-side lookup that works regardless
          of the home's modes - the hermes-agent.nix sshAccess lesson).
        '';
      };
    };
  };

  config = mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.harness != {};
          message = "MODULES.services.datalabHarness.harness must list at least one harness.";
        }
        {
          assertion = cfg.knownHosts != "";
          message = "MODULES.services.datalabHarness.knownHosts must pin datalab's host keys before the wrapper may dial.";
        }
        {
          # hc validates terminal names as 1-32 of [a-z0-9-_] (measured 2026-11-11); the
          # wrapper prefixes "dl-", so the harness name itself must fit the rest and the
          # charset. Fail at eval, not on first `datalab-harness <name>`.
          assertion =
            lib.all (n: builtins.match "[a-z0-9_-]{1,29}" n != null) (builtins.attrNames cfg.harness);
          message = "every MODULES.services.datalabHarness.harness name must be 1-29 chars of a-z 0-9 - _ (hc terminal-name charset, minus the dl- prefix).";
        }
      ];

      sops.secrets.${cfg.keySecret} = {
        owner = "root";
        mode = "0400";
      };

      # b64 secret -> real keyfile, znapzend's decode doctrine (sops lands the mount first;
      # this unit is the only writer, 0700 dir keeps the key out of every group listing).
      systemd.services.datalab-harness-key = {
        description = "Decode the datalab harness ssh key into ${keyDir}";
        after = ["sops-install-secrets.service"];
        # sysinit-reactivation.target, not just multi-user: the 26.05 switcher's own
        # "start new units" pass silently skips fresh oneshots after a deploy (measured
        # hp 2026-11-11: enabled, dead, zero journal entries - the same lesson
        # modules/services/herdr.nix documents for its merge units). Attaching here makes
        # every switch re-run the decode, which is idempotent anyway.
        wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "datalab-harness-key" ''
            set -eu
            umask 077
            mkdir -p ${keyDir}
            base64 -d ${config.sops.secrets.${cfg.keySecret}.path} > ${keyPath}
            ${
              if cfg.terminalAccess.enable
              then ''
                # The terminal account's LOGIN SHELL execs this very ssh, so it must read
                # the key: the one deliberate widening of the doctrine. 0440 root:<user> is
                # accepted by OpenSSH 10.6's permission check (measured on hp 2026-11-11:
                # group-readable key offered cleanly, no "UNPROTECTED"; group write WOULD
                # trip it), and only the single-member service group gains access. The
                # directory follows 0750 (listing needs no rights: the config names both
                # paths absolutely).
                chmod 0440 ${keyPath}
                chgrp ${cfg.terminalAccess.user} ${keyPath} ${keyDir}
                chmod 0750 ${keyDir}
              ''
              else ''
                chmod 0400 ${keyPath}
              ''
            }
          '';
        };
      };

      # The terminal account itself - hp's third herdr identity after root and hermes
      # (hosts/hp + modules/services/herdr.nix wire the server unit and catalog row;
      # MODULES.networking.dns.aliases gives the phone a second name for the same box).
      # Service user like hermes: no password ever, no linger (the cli.service unit owns
      # the server), bash-dark login shell = paneShell above. authorized_keys.d is the
      # root-side key lookup (the hermes lesson: it survives any home-dir modes).
      users.users.${cfg.terminalAccess.user} = lib.mkIf cfg.terminalAccess.enable {
        isSystemUser = true;
        group = "${cfg.terminalAccess.user}";
        home = "/var/lib/${cfg.terminalAccess.user}";
        createHome = true;
        shell = "${paneShell}/bin/datalab-terminal-shell";
        openssh.authorizedKeys.keys = cfg.terminalAccess.authorizedKeys;
        # The app-menu shims live ONLY in this account's per-user profile -
        # /etc/profiles/per-user/<user>/bin, which leads the PATH of both the herdr
        # unit and the transient core the desktop app spawns over ssh (verified from
        # /proc and systemctl on hp 2026-11-11). They must NOT reach the system
        # profile: root's own menu on hp (and every plain shell on the box) must keep
        # resolving `pi`/`opencode` to whatever hp itself installs, not to the cluster.
        packages = map agentShim (builtins.attrNames agentLaunchers);
      };
      users.groups.${cfg.terminalAccess.user} = lib.mkIf cfg.terminalAccess.enable {};

      # The pane shell is a store path baked into /etc/passwd AND into the running herdr
      # server's $SHELL env: a changed sshConfig/paneShell needs `systemctl restart
      # herdr-server-${cfg.terminalAccess.user}` to take effect (the unit's own
      # restartTriggers only watch the herdr package and its config.toml - same known
      # staleness class as hermes' unit PATH, documented 2026-11-11).

      # The pin file sshConfig's UserKnownHostsFile reads. Public material (hostKeys
      # doctrine), world-readable; the PRIVATE key lives only in the 0700 ${keyDir}.
      environment.etc."ssh/datalab/known_hosts" = {
        text = cfg.knownHosts;
        mode = "0444";
      };

      environment.systemPackages = [wrapper] ++ builtins.attrValues agentLaunchers;
    }

    # ---------------------------------------------------------------- web harnesses -------
    # A harness with `port` (UltraTrainer) is reachable without the human doing anything:
    # a persistent loopback ssh tunnel on hp (`hp:<port> -> head:<port>`, the same -F
    # config + key the panes use, verified 2026-11-13 to forward fine for this account)
    # plus a Traefik subdomain under the `datalab` DNS alias (dnsmasq's address= record
    # matches the WHOLE subtree, so ultra-trainer.datalab.hp already resolved the moment
    # `datalab` was aliased - this block only adds the router + cert). The app itself
    # only starts when the harness is spawned from herdr (dl-ultra-trainer); until then
    # Traefik holds the connection refused-open at the loopback end and answers 502 -
    # spawning from the menu is the documented on-switch.
    (mkIf (webHarnesses != {}) {
      assertions = [
        {
          # The cert lives one label below the zone (datalab.hp is itself an alias of
          # this zone), and step-ca wildcards are label-perfect - the CA must be told.
          assertion = config.MODULES.networking.traefik.enable;
          message = "datalabHarness web harnesses (a harness with `port`) need MODULES.networking.traefik.enable to publish them.";
        }
      ];

      MODULES.networking.step-ca.extraAllowDns = [
        "*.datalab.${config.MODULES.networking.traefik.domain}"
      ];

      # One tunnel unit per web harness. ssh -N -o ExitOnForwardFailure: bind-or-die, so
      # a stale forward never silently shadows the port; BatchMode + the pinned
      # known_hosts = zero interactive prompts; ServerAlive reaps a zombie forward when
      # tun0 dies without a FIN (same policy as the panes, ~45s: this fronts a UI, not a
      # login). StartLimitIntervalSec=0: Restart=always must survive the TU gateway's
      # session-expiry windows (dial fails every ConnectTimeout+RestartSec until TU
      # re-auths) - the default 5-in-10s would FAIL the unit permanently on a bad night
      # and need a manual reset-failed (the tuvpn unit's own reasoning, same cadence).
      systemd.services =
        lib.mapAttrs' (
          n: hc:
            lib.nameValuePair "datalab-web-${n}" {
              description = "Loopback tunnel to the ${n} web UI on the TU cluster (hp:${toString hc.port} -> head:${toString hc.port})";
              wantedBy = ["multi-user.target"];
              after = ["network-online.target" "tuvpn.service" "datalab-harness-key.service"];
              wants = ["network-online.target" "datalab-harness-key.service"];
              unitConfig.StartLimitIntervalSec = 0;
              serviceConfig = {
                Type = "simple";
                User = cfg.terminalAccess.user;
                ExecStart = "${pkgs.openssh}/bin/ssh -F ${sshConfig} -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -L 127.0.0.1:${toString hc.port}:localhost:${toString hc.port} datalab-harness";
                Restart = "always";
                RestartSec = "10s";
                # A failed DIAL is this unit's normal Tuesday (TU re-auth windows, the
                # gateway's DNS being transiently unresolvable - measured on the hp switch
                # 2026-11-13 14:17: a 1-minute WAN/DNS blip made ssh exit 255 during
                # activation, systemd filed the unit failed, and the whole switch rolled
                # back on status 4). ssh's network-failure code is 255: treat it as a
                # clean exit so the unit never enters `failed` - Restart=always re-dials
                # anyway, and a persistent outage shows as auto-restart churn, not as a
                # failed unit (StartLimitIntervalSec=0 above keeps it retrying forever).
                SuccessExitStatus = "255";
              };
            }
        )
        webHarnesses;

      # Traefik: one subdomain per web harness -> its loopback tunnel. The service KEY is
      # "<webSubdomain>.datalab" so hostOf yields "<webSubdomain>.datalab.hp" - one label
      # below the `datalab` alias, whose dnsmasq address= record already answers the whole
      # subtree, so DNS needs nothing new; joining traefik.services is what mints the
      # router + the step-ca cert (the extraAllowDns wildcard above). Tailnet-only.
      MODULES.networking.traefik.services =
        lib.mapAttrs' (
          n: hc:
            lib.nameValuePair "${hc.webSubdomain}.${cfg.terminalAccess.user}"
            "127.0.0.1:${toString hc.port}"
        )
        webHarnesses;

      # No LIMITS row by design: the table is fleet-static (limits.nix rejects unknown
      # rows), and this module's other units (datalab-harness-key, the panes' ssh under
      # the datalab herdr server) ride the user-slice defaults with no row either. An
      # idle ssh -N is ~10M and frames flow only while a browser is open; if one ever
      # misbehaves, the fix is a `datalabWeb` row in the table proper.
    })
  ]);
}
