# Slurm, one node: slurmctld and slurmd side by side on the same machine, so `srun`/`sbatch`
# work like a cluster (allocation, queue, GPU as a schedulable resource, job cgroups) without a
# second host. Nothing here assumes a cluster grows - but nothing blocks it either: the daemon
# pair, the munge key and the node record are each independent knobs.
#
# Loopback by construction. `SlurmctldHost=<host>(127.0.0.1)` makes every client dial
# 127.0.0.1, and no firewall rule is opened, so the daemons' listeners (which bind INADDR_ANY -
# Slurm has no bind-address key) are unreachable from the tailnet. That is also why this service
# adds NO edge to modules/security/service-graph.nix: nothing accepts or dials tailnet TCP.
# Moving it onto the tailnet later is one option (`listenAddr`) plus the edge rows in both roles,
# or Suricata fires SG-DRIFT on every job submission.
#
# Gaps found in nixpkgs' services/computing/slurm/slurm.nix against the 25.11.8.1 it builds
# (all verified on legion5 2026-10-29 with the real binaries, not from docs):
#   * It never emits `SlurmctldHost`, and 25.11 FATALS without one - `_load_slurmctld_host()`
#     in src/common/read_config.c logs "No SlurmctldHost defined." and fails the config load.
#     Its `controlMachine` option cannot substitute: the file's keys are matched case-sensitively
#     against a table entry spelled `ControlMachine`, so the module's lowercase
#     `controlMachine=` line is an unknown key. Hence this module writes SlurmctldHost itself
#     through extraConfig and leaves controlMachine at its null default.
#   * The 25.11 syntax is `SlurmctldHost=<name>(<addr>)` - parentheses. The widely copied
#     space form (`SlurmctldHost=name addr`) is a parse error: "Parsing error at unrecognized
#     key". Measured, it took down every client command including `sinfo`.
#   * Plain `DebugLevel` is gone from slurm.conf in 25.11 (`SlurmctldDebug`/`SlurmdDebug`
#     survive). Putting it in extraConfig makes the whole file unparseable.
#   * The munge module requires the key file to ALREADY exist (its unit chmods it and passes it
#     to munged, it never creates it), and its default path /etc/munge/munge.key is inside the
#     read-only /etc. This module owns creation, into munged's own StateDirectory.
#   * slurmd's cgroup/v2 path creates the slurmstepd scope through a dbus call to the SYSTEM
#     manager, so it needs the unit's Delegate=yes (nixpkgs does set that). Running the same
#     config as an ordinary user dies with "systemd scope for slurmstepd could not be set" -
#     which is a permissions artifact, not a config fault (that is what the /tmp/opencode/slurm-proto
#     run in this session established).
#
# Node resources must be spelled out. slurm.conf.5: RealMemory's "default value is 1" (MiB) and
# slurmd validates CPUs/RealMemory against the real machine at registration, so an
# under-configured node drains and an over-configured one goes INVAL (a TmpDisk mismatch only
# logs "low tmp_disk size"). The host supplies the line from `slurmd -C` rather than this module
# guessing hardware it cannot see at eval time.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkOption
    mkIf
    mkEnableOption
    types
    optionalString
    optional
    concatStringsSep
    ;

  cfg = config.MODULES.services.slurm;

  nodeName = config.networking.hostName;

  # The slurmstepd scopes are transient units, so LIMITS (which names services) can never reach
  # them - the slice is where the job ceiling belongs.
  sliceName = cfg.jobSlice.name;

  mungeKeyPath = "/var/lib/munge/munge.key";

  # Only forced when a shared key is actually configured: a sops.secrets lookup on the literal
  # name "null" would otherwise ask sops for a secret that does not exist, on every host that
  # never touches this option. The secret itself is declared by the HOST (sops keys are host
  # facts per AGENTS.md), not from here, for the same reason.
  mungeKeySource =
    if cfg.mungeKeySecret == null
    then null
    else config.sops.secrets.${cfg.mungeKeySecret}.path;

  mungeKeySetup = pkgs.writeShellScript "slurm-munge-key" ''
    set -eu
    ${
      if cfg.mungeKeySecret != null
      then ''
        # Distributed key (sops): re-install on every start so a rotation lands on the next restart.
        install -m 0400 -o munge -g munge -f ${mungeKeySource} ${mungeKeyPath}
      ''
      else ''
        # Host-local key: Slurm only ever needs every process ON this box to agree on it, and a
        # key that never leaves the machine cannot be leaked by the repo. Written once into
        # munged's StateDirectory (which znapzend's zroot/root job already covers).
        if [ ! -s ${mungeKeyPath} ]; then
          umask 077
          LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 128 > ${mungeKeyPath}.tmp
          mv ${mungeKeyPath}.tmp ${mungeKeyPath}
        fi
      ''
    }
    chown munge:munge ${mungeKeyPath}
    chmod 0400 ${mungeKeyPath}
  '';

  gresConf = pkgs.writeTextDir "gres.conf" ''
    # Generated by modules/services/slurm.nix. Read from the directory that holds slurm.conf,
    # which is where nixpkgs points SLURM_CONF.
    AutoDetect=${cfg.gpu.autoDetect}
  '';
in {
  options.MODULES.services.slurm = {
    enable = mkEnableOption "a single-node Slurm cluster (slurmctld + slurmd on this host)";

    listenAddr = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = lib.literalExpression "config.MODULES.networking.tailscale.hostIP";
      description = ''
        Address the node record points clients at. Loopback keeps the cluster on-box and off the
        tailnet, which is what lets it stay out of the service-graph edge table; set it to this
        host's Tailscale IP (and add the edges, in both roles, plus a firewall rule) before
        pointing another machine at it.
      '';
    };

    clusterName = mkOption {
      type = types.str;
      default = nodeName;
      description = "Slurm cluster name (shows up in prompts, logs and accounting records).";
    };

    partitionName = mkOption {
      type = types.str;
      default = "batch";
      description = "The one partition's name; it is the default and holds this node.";
    };

    nodeAttrs = mkOption {
      type = types.str;
      default = "";
      example = ''
        CPUs=16 Boards=1 SocketsPerBoard=1 CoresPerSocket=8 ThreadsPerCore=2 RealMemory=31393
      '';
      description = ''
        Everything after `NodeName=<host>` on the node line - a per-host hardware fact, so it
        belongs to the host file. Generate it with `slurmd -C` on the machine and drop the
        leading NodeName token. Do not hand-write RealMemory: slurmd compares the configured
        values against the live machine at registration and an over-declared node goes INVAL.
        Do not hand-write TmpDisk either - that comes from scratch.tmpDiskMB, sized to the
        dataset's refquota rather than the hardware.
      '';
    };

    gpu = {
      enable = mkOption {
        type = types.bool;
        default = config.MODULES.hardware.nvidia.enable or false;
        defaultText = lib.literalExpression "config.MODULES.hardware.nvidia.enable";
        description = ''
          Manage the GPU as a generic resource (GresTypes=gpu plus a gres.conf that detects the
          card). Off on a host with no accelerator, and the gpu:1 count in the node record comes
          along only when it is on.
        '';
      };
      autoDetect = mkOption {
        type = types.str;
        default = "nvidia";
        example = "nvml";
        description = ''
          gres.conf AutoDetect backend. `nvidia` (Slurm 24.11+) reads the device files and needs
          no library; `nvml` also asks the driver, which is what you want for MIG slices or
          NVLink topology. legion5 measured `nvidia` finding the RTX 4060 Laptop without
          LD_LIBRARY_PATH help from nixpkgs (its slurmd unit only sets that for the datacenter
          driver), so the library-free path is the default.
        '';
      };
    };

    scratch = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Put job temporary storage on this host's scratch path instead of /tmp, and make sure the
          path has the ownership the requesting user needs. The dataset itself is a disk-layout
          fact and lives in the host's disko.nix (PLAN §4.3); this only owns its mode/owner and
          Slurm's use of it.
        '';
      };
      path = mkOption {
        type = types.str;
        default = "/scratch";
        description = "Mountpoint of the unbacked scratch dataset.";
      };
      owner = mkOption {
        type = types.str;
        default = "root";
        example = "akos";
        description = ''
          Owner of the scratch root. The classic shared-node answer is root with a sticky mode
          below (everyone writes, nobody deletes anyone else's files); a single-person laptop that
          wants sole ownership names its user here.
        '';
      };
      group = mkOption {
        type = types.str;
        default = "users";
        description = "Group of the scratch root.";
      };
      mode = mkOption {
        type = types.str;
        default = "1777";
        example = "0755";
        description = ''
          Mode of the scratch root. Sticky + world-writable is the traditional /scratch: any job
          user can create and replace its own files, and cannot clobber another's.
        '';
      };
      asTmpFS = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Point Slurm's TmpFS at the scratch path. In Slurm 25.11 TmpFS is *not* a job
          environment feature: it is the filesystem slurmd measures its TmpDisk report from
          (get_mach_stat.c), where slurmstepd places X11 forwarding files, and what the man
          page means when it says jobs "should use" this location. The legacy per-job
          directory (SLURM_TMPDIR + TMPDIR, created when a job passed --tmp) was removed
          upstream - the string appears nowhere in 25.11.8.1's sources or built slurmd,
          and slurmstepd has no pn_min_tmp_disk reference at all; it even dropped TMPDIR
          to a plain "if unset, set /tmp" fallback (task.c). Measured on legion5
          2026-10-29: a --tmp=2048 batch job saw TMPDIR=/tmp with no SLURM_TMPDIR. So
          --tmp is scheduler-side accounting only (see tmpDiskMB), and the per-job scratch
          convention is the job's own: mkdir -p ${cfg.scratch.path}/$SLURM_JOB_ID works
          under the sticky 1777 root this module sets. The point of all of it for this
          fleet: legion5's /tmp is NOT tmpfs, it is a directory on zroot/root - exactly
          the dataset znapzend snapshots - so job scratch belongs on this dataset instead.
          (Slurm's replacement for automatic private dirs is namespace/tmpfs, which mounts
          a RAM tmpfs per job - deliberately not used: this wants disk, not more RAM.)
        '';
      };
      tmpDiskMB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 204800;
        description = ''
          The node record's TmpDisk, in MiB - the scheduler's capacity for job --tmp
          requests, rendered as `TmpDisk=` on the NodeName line. Two reasons it must be
          spelled explicitly: (1) slurmctld validates a --tmp request against the
          CONFIGURED value only (node_scheduler.c compares against config_ptr->tmp_disk),
          and a static node's registration - where slurmd reports the real filesystem size
          measured from TmpFS - never backfills the record (node_mgr.c copies it for
          dynamic nodes only, and merely logs "low tmp_disk size" when registration comes
          in below it); without this option every --tmp request is rejected (measured on
          legion5 2026-10-29: TmpFS set, --tmp=2048 -> "Temporary disk specification can
          not be satisfied", scontrol showed TmpDisk=0). (2) tmp is a cons_tres-tracked
          resource, so this number is what keeps concurrent jobs' declared scratch from
          oversubscribing the dataset's quota. Set it to the scratch dataset's refquota in
          MiB (200G = 204800) from the host's disko.nix.
        '';
      };
    };

    jobSlice = {
      name = mkOption {
        type = types.str;
        default = "slurm";
        description = ''
          Slice slurmd and its slurmstepd scopes start in - given bare, both renderings
          append the unit suffix (the unit's Slice= and cgroup.conf CgroupSlice, which the
          man page says must agree; cgroup.conf wants the full "<name>.slice" - slurmd
          forwards it verbatim as a systemd property). It exists so the job ceiling has a
          name: transient scopes cannot be LIMITS rows.
        '';
      };
      tasks = mkOption {
        type = types.nullOr types.ints.positive;
        default = 8192;
        example = 1024;
        description = ''
          TasksMax for the whole slice - the fork-bomb answer for job code, which is the one
          thing here that runs arbitrary programs. Threads count, so a torch DataLoader with
          many workers wants real headroom; null leaves it at systemd's default.
        '';
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "800%";
        description = "CPUQuota for every job together. Null = uncapped.";
      };
      memHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "24G";
        description = "MemoryHigh for the slice - the line where reclaim pressure starts.";
      };
      memMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "28G";
        description = ''
          MemoryMax for the slice. Left unset by default: the honest wall on a laptop is whatever
          the person sitting at it is willing to give up, and a wrong number here throttles real
          work in a way that takes an afternoon to notice.
        '';
      };
    };

    mungeKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "slurm/munge_key";
      description = ''
        Name of a sops key holding a SHARED munge key, for the day a second node joins: munge
        authenticates daemon-to-daemon, so both sides must hold the same secret. The host that
        sets this must also declare the secret itself (`sops.secrets.<name> = {};` in its own
        file - sops keys are host facts per AGENTS.md).

        With the default null the key is generated on first start into /var/lib/munge and never
        leaves the machine. For a single node that is the better answer: there is nothing to
        distribute, the key rides znapzend's zroot/root snapshots, and no fleet-wide secret gets
        added whose blast radius nobody remembers.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Appended verbatim to slurm.conf.";
    };

    extraCgroupConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Appended verbatim to cgroup.conf.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nodeAttrs != "";
        message = ''
          MODULES.services.slurm.nodeAttrs is empty, so the node would be configured with
          Slurm's defaults - and RealMemory's default is 1 MiB, which schedules nothing. Fill it
          in on the host from that machine's own `slurmd -C` output.
        '';
      }
      {
        assertion = cfg.mungeKeySecret == null || (config.MODULES.security.sops.enable or false);
        message = "MODULES.services.slurm.mungeKeySecret needs MODULES.security.sops.enable.";
      }
      {
        # asTmpFS without a sized node record is inert: slurmctld rejects every --tmp
        # against TmpDisk=0, so the TRES capacity that keeps job scratch honest does not
        # exist (scratch.tmpDiskMB documents the source path). Fail at eval instead.
        assertion = !(cfg.scratch.enable && cfg.scratch.asTmpFS) || cfg.scratch.tmpDiskMB != null;
        message = ''
          MODULES.services.slurm.scratch.tmpDiskMB must name the scratch dataset's refquota in
          MiB (e.g. 204800 for 200G) while scratch.asTmpFS is on: slurmctld only grants --tmp
          against the node record's CONFIGURED TmpDisk, so an unset one rejects every --tmp
          request and the tmp TRES tracks nothing. Set it, or turn scratch.asTmpFS off.
        '';
      }
      {
        # Two TmpDisk= tokens on one NodeName line: slurm's conf parser takes one silently.
        assertion = cfg.scratch.tmpDiskMB == null || !lib.strings.hasInfix "TmpDisk=" cfg.nodeAttrs;
        message = ''
          MODULES.services.slurm.nodeAttrs hand-writes TmpDisk= while scratch.tmpDiskMB also
          renders it - keep the keyword in scratch.tmpDiskMB only (it is sized from the same
          refquota the dataset has).
        '';
      }
    ];

    services.munge = {
      enable = true;
      # nixpkgs' default is /etc/munge/munge.key, which is inside the read-only /etc; the unit's
      # StateDirectory is the writable, munge-owned place that survives a rebuild.
      password = mungeKeyPath;
    };

    # Root-owned pre-start (the `+`), ahead of nixpkgs' own chmod-only ExecStartPre: munged runs
    # as the munge user and cannot create its own key.
    systemd.services.munged.serviceConfig.ExecStartPre = lib.mkBefore ["+${mungeKeySetup}"];

    services.slurm = {
      server.enable = true;
      client.enable = true;

      clusterName = cfg.clusterName;

      nodeName = [
        (concatStringsSep " " (
          [
            nodeName
            "State=UNKNOWN"
          ]
          ++ (lib.splitString " " cfg.nodeAttrs)
          ++ optional cfg.gpu.enable "Gres=gpu:1"
          # The scheduler's --tmp ceiling lives on the node line, not in TmpFS - see the
          # scratch.tmpDiskMB option for why.
          ++ optional (cfg.scratch.enable && cfg.scratch.asTmpFS && cfg.scratch.tmpDiskMB != null)
          "TmpDisk=${toString cfg.scratch.tmpDiskMB}"
        ))
      ];

      partitionName = [
        "${cfg.partitionName} Nodes=${nodeName} Default=YES MaxTime=INFINITE State=UP"
      ];

      # nixpkgs' default (proctrack/linuxproc) is documented as able to lose processes that get
      # reparented to init, which is precisely what a daemonised training run does. The cgroup
      # tracker is also the one the Contain prolog flag and pam_slurm_adopt need.
      procTrackType = "proctrack/cgroup";

      extraCgroupConfig = ''
        # cgroup/v1 is deprecated upstream; NixOS is unified-hierarchy-only, so name v2 rather
        # than let the plugin autodetect.
        CgroupPlugin=cgroup/v2
        # The FULL unit name, ".slice" suffix included - slurmd hands this string straight to
        # systemd as the transient scope's Slice= property (cgroup_dbus.c's
        # _set_scope_properties), and a bare "slurm" is rejected: "Invalid unit name 'slurm'",
        # "systemd scope for slurmstepd could not be set", slurmd start timeout (measured on
        # legion5 2026-10-29, first deploy). Slurm's own default spells it
        # DEFAULT_SYSTEM_CGSLICE "system.slice" (cgroup_v2.c:66).
        CgroupSlice=${sliceName}.slice
        # Per-job RAM/cpuset walls. ConstrainRAMSpace is what keeps a job that exceeds --mem from
        # reaching the desktop session; the kernel OOM-kills inside the job's cgroup instead.
        ConstrainRAMSpace=yes
        ConstrainCores=yes
        ${cfg.extraCgroupConfig}
      '';

      extraConfigPaths = optional cfg.gpu.enable gresConf;

      extraConfig = ''
        # 25.11 requires this and nixpkgs never emits it - see the header. Note the parentheses.
        SlurmctldHost=${nodeName}(${cfg.listenAddr})
        AuthType=auth/munge
        CredType=cred/munge
        SlurmctldPort=${toString config.PORTS.slurmctld}
        SlurmdPort=${toString config.PORTS.slurmd}
        # Left at root deliberately: slurmd has to setuid to the job user and mount its scope.
        SlurmdUser=root
        TaskPlugin=task/cgroup
        JobAcctGatherType=jobacct_gather/cgroup
        ${optionalString cfg.gpu.enable "GresTypes=gpu"}
        ${optionalString (cfg.scratch.enable && cfg.scratch.asTmpFS) "TmpFS=${cfg.scratch.path}"}
        # A laptop reboots out of a suspended session: 2 lets slurmd re-register even when it
        # starts before the controller is reachable, instead of sitting DEAD until restarted.
        ReturnToService=2
        # SlurmdParameters=config_overrides is NOT set: it silences the INVALID_REG check, and
        # that check is the only thing telling us the node line and the hardware disagree.
        ${cfg.extraConfig}
      '';
    };

    systemd.slices.${sliceName} = {
      description = "Slurm jobs (${cfg.clusterName})";
      after = ["network.target"];
      sliceConfig =
        {
          CPUAccounting = true;
          MemoryAccounting = true;
          IOAccounting = true;
          PIDAccounting = true;
        }
        // lib.filterAttrs (_: v: v != null) {
          TasksMax = cfg.jobSlice.tasks;
          CPUQuota = cfg.jobSlice.cpuQuota;
          MemoryHigh = cfg.jobSlice.memHigh;
          MemoryMax = cfg.jobSlice.memMax;
        };
    };

    # The unit and the cgroup.conf entry have to name the same slice (cgroup.conf's CgroupSlice
    # documents the pairing). Jobs' slurmstepd scopes start in the slice too, so this is the one
    # place that covers daemon and workload.
    systemd.services.slurmd = {
      after = ["${sliceName}.slice"];
      wants = ["${sliceName}.slice"];
      serviceConfig.Slice = "${sliceName}.slice";
    };

    # Self-heal the boot-time name-resolution race. Both daemons canonname-resolve the
    # machine's own hostname while binding their listener, and on a cold boot NOTHING can
    # answer yet: tailscale has not written its 127.0.0.2 /etc/hosts line, dnsmasq/MagicDNS
    # (resolv.conf's only nameserver) is not up, and nss files cannot save the day anyway
    # because printing.nix's avahi nssmdns4 puts `mdns4_minimal [NOTFOUND=return]` BEFORE
    # files in nsswitch (legion5, cold boot 2026-10-30 08:16:51: "getaddrinfo((null):6817)
    # failed: Name or service not known" -> "Unable to listen to file descriptors" for
    # slurmctld, "Unable to bind listen port (6818)" for slurmd, exit 1 in ~40ms, and
    # squeue stayed dead until a human restarted it 13 hours later). A plain retry beats
    # ordering debt against a resolver stack no unit declares: the second attempt lands
    # seconds after tailscale/dnsmasq arrive. ReturnToService=2 above is the same idea on
    # the slurmd re-registration side.
    systemd.services = {
      slurmctld.serviceConfig = {
        Restart = "on-failure";
        RestartSec = 10;
      };
      slurmd.serviceConfig = {
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    # `z` and not `d`: if the scratch dataset is missing, the module must not quietly manufacture
    # a /scratch directory on zroot/root and start writing job scratch INTO the snapshotted
    # dataset it exists to avoid. Then slurmd fails visibly instead. (hp learned the adjacent
    # lesson on 2026-10-26: a declared-but-absent dataset plus a required mount is an emergency
    # shell mid-activation, hence the nofail on the host's mount options.)
    systemd.tmpfiles.rules = mkIf cfg.scratch.enable [
      "z ${cfg.scratch.path} ${cfg.scratch.mode} ${cfg.scratch.owner} ${cfg.scratch.group} -"
    ];

    # The two daemon units' ceilings are LIMITS.slurmctld / LIMITS.slurmd, and the job workload's
    # ceiling is the slice above - both live in their own registries (modules/system/limits.nix
    # owns every per-unit cap; this module only owns the slice, which is job-shaped, not unit-shaped).
  };
}
