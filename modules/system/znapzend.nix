# PLAN.md §4 - ZFS snapshot/backup plan on znapzend (the plan text proposed sanoid+syncoid,
# but the user decision wins: "no i chose znapzend, i already use it it can be easily
# configured through nix" - one naming scheme, one daemon; legion5 has run this service
# productively for a year).
#
# Three-copy layering (§4.1): L1 = local znap_* snapshots on every host; L2 = hp pushes
# zroot/persist/hp to akos01 over Tailscale (znapzend daemon lives on the SOURCE and prunes
# the destination as part of replication - akos01 needs no schedule for the mirror, §4.2's
# "prune-only, mirror hp" row is just "do nothing there"); L3 = the daily pg_dumpall into
# persist/hp/dump, which gets carried by the same replication and expires with it.
#
# Plan-syntax crib for the rows below (§4.2's N-hourly/daily/weekly table, znapzend style):
#   24/14/8  ->  1d=>1h,2w=>1d,8w=>1w
#   12/7/4   ->  1d=>1h,7d=>1d,4w=>1w  (legion5 laptop: lighter)
# The retention window of the first tier bounds the hourly count (24h window => 24 snaps).
#
# Trust: znapzend sshes as root from the source. hp->akos01 uses a dedicated ed25519 key
# (sops znapzend/ssh_key_b64, base64 so the multiline PEM survives the yaml, decoded to
# /etc/ssh/znapzend/id_ed25519 root-only); its public half is in akos01's root
# authorized_keys. legion5->hp keeps the pre-existing laptop trust, untouched. First run
# needs host-key acceptance once (manual step in PLAN.md deployment notes).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkIf mkMerge types listToAttrs mapAttrs';

  cfg = config.MODULES.system.znapzend;

  # PLAN §4: the forced command a replication source's ssh key is locked to on a destination
  # host (acceptPush below). sshd confines the key to `zfs` sub-commands and nothing else (no
  # shell, no pty, no forwarding) - but the naive form accepted ANY zfs arguments, i.e.
  # `zfs destroy -r zroot/<anything>` and `zfs recv -F` outside the replica were in the stolen-
  # source blast radius. Now: only the subcommand set znapzend's ssh protocol uses, and every
  # dataset-shaped argument (containing / or @) must live under the replica dataset
  # (acceptPush.datasetPrefix) - the destination's real blast radius.
  # znapzend prunes received snapshots from the SOURCE, so `destroy`/`-F` here stay
  # within the same prefix (autoCreation + rollback cleanup); no other host needs it.
  # NOTE on the input path: with a forced command, sshd's do_exec() REPLACES the client
  # command line with the forced one and delivers the client's original command ONLY in
  # $SSH_ORIGINAL_COMMAND (session.c) - reading $@ would reject every legitimate
  # invocation. Parse that env var; argv stays supported so root can exercise the
  # filters locally (`znapzend-shell zfs list ...`).
  znapzendShell = pkgs.writeShellScriptBin "znapzend-shell" ''
    ds_prefix="${cfg.acceptPush.datasetPrefix}"
    die() { echo "znapzend-shell: disallowed: $*" >&2; exit 1; }

    if [ "$#" -eq 0 ]; then
      cmd=''${SSH_ORIGINAL_COMMAND:-}
      [ -n "$cmd" ] || die "no command"
      # Honor the single quotes znapzend wraps around tokens containing characters
      # outside [-/@=_0-9a-z] (snapshot timestamps carry ':') by letting bash
      # re-parse the line - but only after pinning the WHOLE line to that charset:
      # no ; | & $ " backslash ( ) < > { } [ ] * ? ! ~ # % ^ ,tab ,newline survive the
      # gate, so the eval can do nothing but word-split and remove quotes. `=` is IN
      # the charset so the whitelisted `set` verb's property=value operands can reach
      # eval at all (2026-10-25 review nit); a bare `a=b` token after `set --` is
      # inert - it is a positional arg, never an assignment. An
      # unbalanced quote then just fails to parse and $1 stays empty -> die below.
      # The class lives in a variable because a bare ' inside a case-pattern
      # bracket (or a //pattern/ expansion) would open a quote in bash's lexer.
      bad_re="[^-A-Za-z0-9_=/.:,'@ ]"
      if [[ "$cmd" =~ $bad_re ]]; then die "charset"; fi
      eval set -- $cmd
    fi
    if [ "$1" = "zfs" ]; then shift; fi
    case "$1" in
      version)
        [ "$#" -eq 1 ] || die "$*"
        exec ${pkgs.zfs}/sbin/zfs version ;;
      recv|create|destroy|list|get|set|mount|umount) ;;
      *)
        die "$*" ;;
    esac
    # Operand scoping. A bare pool name (zroot, rpool) contains no "/" so a slash test
    # alone would let `zfs destroy zroot` through - pool-level operands must be pinned
    # positively, per verb:
    #   recv/create/mount/umount: every non-option operand IS a dataset
    #     (znapzend remote ops never pass -o key=value through these) -> must be under
    #     the prefix; `zfs set a=b <ds>`'s property argument would also fail this, which
    #     is correct here (set belongs to the next rule).
    #   destroy: same, modulo the comma grammar documented at destroy_operand.
    #   set: operands are `property=value` pairs plus datasets - pairs pass, everything
    #     else must be under the prefix (blocks `zfs set x=y zroot`).
    #   list/get: read-only; slash-bearing operands (datasets/snapshots) still pinned,
    #     bare names only ever leak inventory.
    # And per COMMA ELEMENT, not per token: znapzend's combinedDestroy (ZFS.pm) prunes
    # every expired snapshot as ONE comma-joined argument in ZFS grammar
    # `fs@snapA,snapB` - only the FIRST element carries the dataset, and ZFS parses a
    # later element as a snapshot OF THAT SAME dataset, never as another target. So
    # destroy_operand pins the first element under the replica prefix and accepts bare
    # continuation names; `zroot/persist/hp@a,zroot/root@b` still dies on the second
    # element's "/". (The old every-element rule rejected znapzend's own legitimate
    # multi-snapshot prune - 2026-10-25 review #2, destination snapshots piled up.)
    under_prefix() {
      case "$1" in
        "$ds_prefix"|"$ds_prefix"/*|"$ds_prefix"@*) return 0 ;;
        *) return 1 ;;
      esac
    }
    # check $2 against every comma element of $1 (empty elements die: `a,` / `,a` /
    # `a,,b` are exactly where a foreign name hides).
    every_element() {
      local elem IFS=,
      case "$1" in ,*|*,|*,,*) return 1 ;; esac
      for elem in $1; do "$2" "$elem" || return 1; done
      return 0
    }
    pinned_operand() { under_prefix "$1"; }
    # zfs-destroy comma grammar (see above): first element fully pinned, continuation
    # elements snapshot names of the SAME dataset - any / or @ in them means someone
    # is trying to point the destroy elsewhere.
    destroy_operand() {
      local first=1 elem IFS=,
      case "$1" in ,*|*,|*,,*) return 1 ;; esac
      for elem in $1; do
        if [ "$first" = 1 ]; then
          under_prefix "$elem" || return 1
          first=0
        else
          case "$elem" in */*|*@*) return 1 ;; esac
        fi
      done
      return 0
    }
    # list/get only pin elements that look like datasets (contain / or @); the -t
    # type list ("filesystem,volume") and property names pass untouched.
    read_operand() {
      case "$1" in
        */*|*@*) under_prefix "$1" ;;
        *) true ;;
      esac
    }
    sub="$1"
    for a in ''${@:2}; do
      case "$a" in -*) continue ;; esac
      case "$sub" in
        destroy)
          destroy_operand "$a" || die "$*" ;;
        recv|create|mount|umount)
          every_element "$a" pinned_operand || die "$*" ;;
        set)
          case "$a" in
            *=*) ;;
            *) every_element "$a" pinned_operand || die "$*" ;;
          esac ;;
        list|get)
          every_element "$a" read_operand || die "$*" ;;
      esac
    done
    exec ${pkgs.zfs}/sbin/zfs "$@"
  '';

  # Destination hostnames (user@ stripped) across all jobs - the ssh-alias blocks below
  # are generated from them.
  hostnameOf = h: lib.last (lib.splitString "@" h);
  destHosts = lib.unique (
    lib.concatMap (j: lib.mapAttrsToList (_: d: hostnameOf d.host) j.destinations)
    cfg.jobs
  );
  # "root@akos01" -> "root@znap-akos01": ssh matches Host blocks on the hostname part
  # only, so the alias prefix lands after the @.
  aliasHost = h: let
    parts = lib.splitString "@" h;
  in
    if parts == [h]
    then "znap-${h}"
    else "${lib.concatStringsSep "@" (lib.init parts)}@znap-${lib.last parts}";

  jobType = types.submodule {
    options = {
      dataset = mkOption {
        type = types.str;
        description = "Source dataset (also the zetup key).";
      };
      recursive = mkOption {
        type = types.bool;
        default = true;
      };
      plan = mkOption {
        type = types.str;
        example = "1d=>1h,2w=>1d,8w=>1w";
        description = "Local retention plan (znapzend retention=>interval syntax).";
      };
      destinations = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                example = "root@akos01";
              };
              dataset = mkOption {
                type = types.str;
              };
              plan = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Destination retention; null = same as local plan.";
              };
            };
          }
        );
        default = {};
      };
    };
  };
in {
  options.MODULES.system.znapzend = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    jobs = mkOption {
      type = types.listOf jobType;
      default = [];
      description = "One entry per source dataset; empty destinations = local-only snapshots.";
    };

    pgDumpDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/pgdump";
      description = ''
        §4.1 L3: when set, a daily 00:05 pg_dumpall (gzipped, host-named) lands in this
        directory and rides the znapzend replication of whatever dataset it sits on - the
        logical dump is the layer that survives a corrupted pool AND a forgotten password
        rotation. Local copies older than 8 weeks are pruned; the replicated copy ages out
        with the destination plan.
      '';
    };

    sshKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "znapzend/ssh_key_b64";
      description = "sops key holding the base64 of the ed25519 private key used for pushes.";
    };

    pgDumpDataset = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "zroot/persist/hp/dump";
      description = ''
        When set (with pgDumpDir), the dump service runs `zfs create -o mountpoint=<pgDumpDir>
        <dataset>` as ExecStartPre: the logical dump then lands ON a real dataset and rides the
        replication of that dataset, not just of the plain directory. tmpfiles still creates the
        mountpoint empty at boot, the dataset lands on the empty dir at first use, later runs
        no-op; the leading "-" is systemd's ignore-failure marker (dataset exists / dir busy).
        If the dir ever holds files before the dataset exists, create fails soft and dumps keep
        writing to the plain dir - same as without this option, just visible via `zfs list`.
      '';
    };

    acceptPush = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Destination side of a replication push: pin the source's ssh public key
          (authorizedKey) to the scoped znapzend forced command (znapzendShell below), so a
          stolen source key can only touch datasetPrefix. The source keeps the normal
          MODULES.system.znapzend.jobs/sshKeySecret config; this option goes on the receiving
          host only.
        '';
      };

      datasetPrefix = mkOption {
        type = types.str;
        default = "";
        example = "zroot/persist/hp";
        description = "The only dataset tree the pushed key may operate on here.";
      };

      authorizedKey = mkOption {
        type = types.str;
        example = "ssh-ed25519 AAAA... znapzend-hp-to-akos01";
        description = "Public key line of the source's replication keypair.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.znapzend = {
        enable = true;
        # pure = no znapzend-managed dataset creation surprises beyond autoCreation of the
        # destination's missing parents; lowmemRecurse mirrors what legion5 runs productively.
        pure = true;
        autoCreation = true;
        logLevel = "warning";
        # /dev/stderr, not a logfile: the daemon's output then lands in journald, rides the
        # existing Alloy->Loki spine, and a silent backup daemon is a visible absence there
        # (§4.6's "freshness is the only signal that matters").
        logTo = "/dev/stderr";
        features.lowmemRecurse = true;
        zetup = listToAttrs (
          map (j: {
            name = j.dataset;
            value = {
              enable = true;
              inherit (j) recursive plan;
              destinations =
                mapAttrs' (
                  n: d: {
                    name = n;
                    value =
                      {
                        # When a dedicated key is configured, push through the znap-* ssh
                        # aliases below so the identity pinning can never catch admin ssh.
                        host =
                          if cfg.sshKeySecret != null
                          then aliasHost d.host
                          else d.host;
                      }
                      // {inherit (d) dataset;}
                      # nixpkgs' destination submodule defaults plan to the source's - leave it
                      # unset rather than null so that default engages.
                      // lib.optionalAttrs (d.plan != null) {
                        plan = d.plan;
                      };
                  }
                )
                j.destinations;
            };
          })
          cfg.jobs
        );
      };
      # (no log file to tail: logTo=/dev/stderr above; the unit's own journal stream is the
      # freshness signal, queryable in Loki as {unit="znapzend"}).
    })

    # ---- §4.1 L3: the logical dump rides the physical replication ----------------------
    (mkIf (cfg.enable && cfg.pgDumpDir != null) {
      assertions = [
        {
          assertion = config.services.postgresql.enable;
          message = "MODULES.system.znapzend.pgDumpDir is set but services.postgresql.enable is false - nothing to dump.";
        }
      ];
      # Runs as postgres via su: pg_dumpall must speak to the socket as the superuser
      # role, while the output dir and the retention prune stay root-owned.
      # Every binary is absolute-pathed: writeShellScript's service PATH is only
      # coreutils/findutils/grep/sed/systemd (no gzip), and su no longer lives in
      # pkgs.shadow on this nixpkgs - it is the separate setuid pkgs.su derivation
      # (both bites made the first 2026-10-26 run of this service die at exit 127).
      systemd.services.znapzend-pg-dump = {
        description = "Daily pg_dumpall into ${cfg.pgDumpDir} (PLAN §4.1 L3)";
        serviceConfig.Type = "oneshot";
        # See MODULES.system.znapzend.pgDumpDataset: idempotent dataset creation for the dump
        # dir, fail-soft like a plain dir when it can't mount (no shell needed - "-" is
        # systemd's ignore-failure marker).
        serviceConfig.ExecStartPre =
          if cfg.pgDumpDataset != null
          then "-${pkgs.zfs}/sbin/zfs create -o mountpoint=${cfg.pgDumpDir} ${cfg.pgDumpDataset}"
          else null;
        serviceConfig.ExecStart = pkgs.writeShellScript "znapzend-pg-dump" ''
          set -euo pipefail
          mkdir -p ${cfg.pgDumpDir}
          out="${cfg.pgDumpDir}/${config.networking.hostName}-$(date +%F).sql.gz"
          ${pkgs.su}/bin/su -s ${pkgs.bash}/bin/bash postgres -c '${
            config.services.postgresql.package
          }/bin/pg_dumpall' | ${pkgs.gzip}/bin/gzip > "$out.part"
          mv "$out.part" "$out"
          chmod 0600 "$out"
          # 8 weeks, mirroring the narrowest fleet retention; the replicated copy on the
          # destination ages out under that destination's own plan.
          find ${cfg.pgDumpDir} -name '*.sql.gz' -mtime +56 -delete
          find ${cfg.pgDumpDir} -name '*.part' -mmin +120 -delete
        '';
      };
      systemd.timers.znapzend-pg-dump = {
        wantedBy = ["timers.target"];
        timerConfig = {
          # §4.2 timer layout: :00 snapshots, :20 pushes - the dump takes 00:05 so
          # tonight's file is inside tonight's push.
          OnCalendar = "*-*-* 00:05:00";
          RandomizedDelaySec = "15m";
          Persistent = true;
          Unit = "znapzend-pg-dump.service";
        };
      };
      systemd.tmpfiles.rules = ["d ${cfg.pgDumpDir} 0700 root root - -"];
    })

    (mkIf (cfg.enable && cfg.sshKeySecret != null) {
      sops.secrets.${cfg.sshKeySecret} = {
        sopsFile = ../../sops/secrets.yaml;
        key = cfg.sshKeySecret;
        owner = "root";
        mode = "0400";
      };
      # The secret lands as base64 text; decode it into the actual key file. Ordering:
      # sops-<key>.service runs before znapzend.service.
      systemd.services.znapzend-ssh-key = {
        description = "Decode the znapzend replication ssh key into /etc/ssh/znapzend";
        requiredBy = ["znapzend.service"];
        before = ["znapzend.service"];
        after = ["sops-install-secrets.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = ''
            ${pkgs.bash}/bin/bash -c 'umask 077; mkdir -p /etc/ssh/znapzend; base64 -d ${
              config.sops.secrets.${cfg.sshKeySecret}.path
            } > /etc/ssh/znapzend/id_ed25519'
          '';
        };
      };
      # znapzend shells out to plain `ssh`, which always reads the SYSTEM client config.
      # Since 2026-11-09 the file itself belongs to modules/networking/ssh-client.nix
      # (herdr's machine catalog writes the same path - two owners of
      # environment.etc."ssh/ssh_config" is the redefine trap), so znapzend contributes
      # its blocks through MODULES.networking.sshClient.blocks like every other consumer.
      # The jobs above were rewritten to address `znap-<host>`; these blocks map each
      # alias back to the real name and pin the replication identity ONLY under that
      # alias. An earlier draft Match'ed the real hostnames for uid 0, which also caught
      # admin ssh from the same root account (IdentitiesOnly + BatchMode => forced-command
      # shell or hard auth failure). Aliased hosts are unreachable by accident either way:
      # nothing but these blocks defines `znap-*`, so a plain `ssh root@akos01` behaves
      # exactly as on any unpinned machine.
      # ORIGINALHOST, not host (hp 2026-10-26, replication had never landed a snapshot):
      # `Match host` tests the RESOLVED target - after the HostName above rewrites
      # znap-akos01 back to akos01 - so `Match host znap-...` never fires, the pin below
      # silently no-ops, and root's default keys bounce off the destination's
      # forced-command-only authorized_keys (sshd logs "penalty: failed authentication",
      # znapzend restart-loops). `Match originalhost` tests the command-line name, which
      # is exactly what only the alias can be - admin ssh to the real hostname stays
      # unaffected.
      # accept-new pins the peer key on the daemon's first connect (documented bootstrap,
      # then it behaves StrictHostKeyChecking=yes); BatchMode keeps failures loud in the
      # journal instead of hanging on a prompt.
      MODULES.networking.sshClient.blocks =
        map (h: ''
          Host znap-${h}
            HostName ${h}
            StrictHostKeyChecking accept-new

          Match originalhost znap-${h} exec "test \"$(id -u)\" = 0"
            IdentityFile /etc/ssh/znapzend/id_ed25519
            IdentitiesOnly yes
            BatchMode yes
        '')
        destHosts;
    })

    # ---- Destination side of a push (§4.1 L2) ------------------------------------------------
    # The receiving host opts in here; the source stays on plain jobs/sshKeySecret. One-way
    # replication trust, scoped: the source's public key is pinned to the forced command above
    # (znapzendShell), so a stolen source key can only run replica-shaped `zfs` verbs under
    # acceptPush.datasetPrefix - no shell, no forwarding, nothing outside the replica.
    (mkIf cfg.acceptPush.enable {
      assertions = [
        {
          assertion = cfg.acceptPush.datasetPrefix != "";
          message = "MODULES.system.znapzend.acceptPush.datasetPrefix must name the replica dataset tree when acceptPush.enable is set.";
        }
        {
          assertion = cfg.acceptPush.authorizedKey != "";
          message = "MODULES.system.znapzend.acceptPush.authorizedKey must carry the source's public key line when acceptPush.enable is set.";
        }
      ];

      users.users.root.openssh.authorizedKeys.keys = [
        (
          "command=\"${znapzendShell}/bin/znapzend-shell\","
          + "no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding "
          + cfg.acceptPush.authorizedKey
        )
      ];

      # The replica tree must EXIST here before any push: znapzend on the source checks
      # the destination at startup and logs "destination does not exist, will be ignored"
      # rather than creating it (hp/akos01 2026-10-26: even with auth fixed, the first
      # replication stayed a no-op because akos01 had no zroot/persist at all - and it
      # can't bootstrap one through the forced command, whose prefix rule rightly rejects
      # creating the PARENT zroot/persist). The receiving host owns its dataset layout,
      # so the tree is ensured here: idempotent `zfs create -p` (fail-soft `-` like the
      # pgDumpDataset pattern - on later boots it's an exists no-op).
      systemd.services.znapzend-accept-push-dataset = {
        description = "Ensure znapzend replica dataset ${cfg.acceptPush.datasetPrefix} exists";
        wantedBy = ["multi-user.target"];
        after = ["zfs-mount.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "-${pkgs.zfs}/sbin/zfs create -p ${cfg.acceptPush.datasetPrefix}";
        };
      };
    })
  ];
}
