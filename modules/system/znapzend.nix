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
      systemd.services.znapzend-pg-dump = {
        description = "Daily pg_dumpall into ${cfg.pgDumpDir} (PLAN §4.1 L3)";
        serviceConfig.Type = "oneshot";
        serviceConfig.ExecStart = pkgs.writeShellScript "znapzend-pg-dump" ''
          set -euo pipefail
          mkdir -p ${cfg.pgDumpDir}
          out="${cfg.pgDumpDir}/${config.networking.hostName}-$(date +%F).sql.gz"
          ${pkgs.shadow}/bin/su -s ${pkgs.bash}/bin/bash postgres -c '${
            config.services.postgresql.package
          }/bin/pg_dumpall' | gzip > "$out.part"
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
      # NixOS ships no /etc/ssh/ssh_config by default, so this entry is ours alone.
      # The jobs above were rewritten to address `znap-<host>`; these blocks map each
      # alias back to the real name and pin the replication identity ONLY under that
      # alias. An earlier draft Match'ed the real hostnames for uid 0, which also caught
      # admin ssh from the same root account (IdentitiesOnly + BatchMode => forced-command
      # shell or hard auth failure). Aliased hosts are unreachable by accident either way:
      # nothing but these blocks defines `znap-*`, so a plain `ssh root@akos01` behaves
      # exactly as on any unpinned machine.
      # accept-new pins the peer key on the daemon's first connect (documented bootstrap,
      # then it behaves StrictHostKeyChecking=yes); BatchMode keeps failures loud in the
      # journal instead of hanging on a prompt.
      environment.etc."ssh/ssh_config".text =
        # managed by modules/system/znapzend.nix
        lib.concatMapStrings (h: ''
          Host znap-${h}
            HostName ${h}
            StrictHostKeyChecking accept-new

          Match host znap-${h} exec "test \"$(id -u)\" = 0"
            IdentityFile /etc/ssh/znapzend/id_ed25519
            IdentitiesOnly yes
            BatchMode yes
        '')
        destHosts;
    })
  ];
}
