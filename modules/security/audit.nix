# PLAN.md §3 - syscall-level inspection. auditd (the only option that survived §3.1's re-check:
# Falco is gone from nixpkgs, Tetragon never was). Rules are the plan's three groups, the
# delivery path is the repo's existing journal->Alloy->Loki spine, and the paging rules ship
# through Grafana's provisioned alerting (the Loki datasource is already provisioned by
# modules/services/loki.nix when Grafana runs beside Loki).
#
# Shipping note: /var/log/audit/audit.log is 0600 root and nixpkgs gives auditd no log_group
# knob; instead of a permissions dance, a tiny root adapter (`audit-forward`) tails the file
# into journald (`systemd-cat -t audit`), and the existing Alloy journal source ships it with
# unit="audit-forward". One more always-on service on each host, zero new open ports or readers.
#
# The per-user execve key (`svc-exec-<user>`) is the fork-bomb / webshell signal from §3.2:
# for a static process tree, an execve that "didn't happen yesterday" is the anomaly. The
# §3.3 Grafana allowlist rule deliberately waits for a week of seeded data - shipping it now
# would page on every python import storm (see the TODO at the rule).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkIf mkMerge types concatMapStringsSep optionalString;

  cfg = config.MODULES.security.audit;

  # §3.2 group 2 - "the it's-over set": rare by construction, so the rules can be global.
  # The two /run/secrets dir watches fire on create/delete/chmod of entries *inside*
  # them (a syscall on a child matches a dir watch through the child's recorded parent
  # entry - auditsc.c); files a directory level deeper are invisible to them, which is
  # what secretReadRules below exist for.
  kernelRules =
    [
      "-a always,exit -F arch=b64 -S mount -S umount2 -S pivot_root -k mount"
      "-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k modules"
      "-a always,exit -F arch=b64 -S ptrace -k ptrace"
      "-a exit,always -F arch=b64 -S bpf -S kexec_load -k kernel"
      "-w /etc/shadow -p wa -k secret-access"
      "-w /etc/sudoers -p wa -k secret-access"
      "-w /etc/sudoers.d/ -p wa -k secret-access"
      "-w /run/secrets -p rwxa -k sops-access"
      "-w /run/secrets.d -p rwxa -k sops-access"
      "-w /var/lib/private/ -p rwxa -k jail-break"
    ]
    # §2.5 model-file trap: writes into ollama's model cache are openat-watches, cheap.
    # Gated: a -w whose path is missing at load time cannot be stat'd, so auditctl
    # registers it as a FILE watch instead of the directory subtree watch it was
    # written as (auditctl.c audit_setup_watch_name) - a rule that can never fire the
    # way its author meant. Hosts without ollama get no dead weight.
    ++ lib.optionals config.MODULES.services.ollama.enable [
      "-w /var/lib/ollama/ -p wa -k model-dir"
    ];

  # Every sops-managed secret gets a read-watch on its OWN inode, wherever it lives:
  # jail rows with a root process keep the blanket /run/secrets mask and relocate their
  # secrets to deeper paths (firefly-iii.nix's /run/jail-secrets/<svc>/app-key), which
  # the dir watches above structurally cannot see. -w on a file matches by inode
  # exactly (audit_watch_compare), at any depth, and loads fine even while the file is
  # absent - the kernel parks the watch on its parent until it appears (audit_watch.c
  # audit_get_nd/kern_path_locked). sops creates these during stage-2 activation,
  # before audit-rules.service runs, so the parents are always there.
  secretReadRules =
    map (
      p: "-w ${p} -p r -k sops-access"
    ) (
      lib.sort (a: b: a < b) (
        lib.unique (lib.mapAttrsToList (_: s: s.path) (config.sops.secrets or {}))
      )
    );

  execRules = map (u: "-a always,exit -F arch=b64 -S execve -F euid=${u} -F key=svc-exec-${u}") cfg.execUsers;

  pgWatch = optionalString config.services.postgresql.enable "-w /var/lib/postgresql/ -p wa -k pg-data";
in {
  options.MODULES.security.audit = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "auditd + the §3.2 rule set + the journald forwarder (server hosts).";
    };

    execUsers = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [
        "postgres"
        "hermes"
        "paseo"
      ];
      description = ''
        Service users whose every execve gets an svc-exec-<user> record. Keep it to the
        code-running class + the DB user (§3.2): each listed uid logs every process it ever
        starts, so noisy builders belong here only while you want them watched. Docker/Podman
        containers run under root's uid and CANNOT be covered this way - they jail via
        egress chains instead.
      '';
    };

    extraRules = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Verbatim auditctl rule lines appended last.";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # nixpkgs synthesizes the -D/-b/-f/-r preamble and the final -e from these options,
      # so group 0 lives here, not in `rules`. enable="lock": auditctl can't be switched off
      # at runtime (reboot to reload rules - the point of §3 being that a rooted service
      # cannot silence the witness); backlogLimit 8192 and failureMode "printk" are the plan's
      # "-b 8192 -f 1" (audit must never silently stop: printk keeps screaming on the console;
      # "panic" is the louder sibling, one bad backlog away from taking hp down - upgrade
      # deliberately if you ever want that). Pinned explicitly so a future nixpkgs default
      # flip cannot quietly relax §3).
      security.audit.enable = "lock";
      security.audit.backlogLimit = 8192;
      security.audit.failureMode = "printk";
      security.auditd.enable = true;

      security.audit.rules = kernelRules ++ secretReadRules ++ execRules ++ cfg.extraRules;

      # The §3.3 shipper. Root tailer; systemd-cat into the journal. The entry label to
      # query is unit="audit-forward" (Alloy maps __journal__systemd_unit -> unit, and
      # journald attributes the tailed lines to the tailer's unit, not to "audit").
      # Catch-up + follow: `ausearch --start boot` first (entries auditd wrote before this
      # unit existed, same raw format as the tail, and bounded to the current boot so a
      # restart re-ships at most this boot's log), then `tail -n 0` follows only - a plain
      # `-n +1` would re-inject every retained rotated log into Loki on every boot.
      systemd.services.audit-forward = {
        description = "Forward /var/log/audit/audit.log into the systemd journal";
        requiredBy = ["multi-user.target"];
        after = ["auditd.service"];
        partOf = ["auditd.service"];
        serviceConfig = {
          Type = "simple";
          ExecStart = ''
            ${pkgs.bash}/bin/bash -c '${pkgs.audit}/bin/ausearch --start boot --raw 2>/dev/null | ${pkgs.systemd}/bin/systemd-cat --identifier=audit --priority=notice; exec ${pkgs.coreutils}/bin/tail -F -n 0 /var/log/audit/audit.log | ${pkgs.systemd}/bin/systemd-cat --identifier=audit --priority=notice'
          '';
          Restart = "always";
          RestartSec = "2s";
          ProtectSystem = "strict";
          ReadOnlyPaths = ["-/var/log/audit"];
        };
      };
    })

    # §3.3 paging rules, provisioned with Grafana (authored once on the hub; like the
    # dashboards dir and the pressure rules, they exist on every host that runs Grafana with
    # its local Loki - the spine is per-host by design).
    (mkIf (cfg.enable && config.MODULES.services.grafana.enable && config.MODULES.services.loki.enable) {
      # nixpkgs exposes fixed provision slots (alerting.rules / .contactPoints / ...); the
      # settings attr is freeform YAML handed to Grafana, whose loader tolerates a bad rule
      # with a log line (worst case: these alerts don't exist until checked live, nothing
      # else regresses). The folder CAN'T be Grafana's "General" root: grafana 13's
      # provisioner "get or create"s it and "General" is reserved ("A folder with that name
      # already exists"), which strangles the whole provisioning module and crash-loops
      # grafana every few seconds (seen live on akos01, 2026-10-25). Use a real folder name.
      services.grafana.provision.alerting.rules.settings = {
        apiVersion = 1;
        groups = [
          {
            orgId = 1;
            name = "audit";
            # Grafana 13 rejects reserved root values on the create path; "Audit" is created
            # by the provisioner on first run and reused after.
            folder = "Audit";
            interval = "1m";
            rules = [
              {
                uid = "audit-kernel-compromise";
                title = "Audit: kernel-level compromise signal (mount/modules/ptrace/kernel/secret-access/jail-break)";
                condition = "C";
                data = [
                  {
                    refId = "A";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "loki";
                    model = {
                      # The kernel quotes filter keys on the wire: audit_log_key() ->
                      # audit_log_untrustedstring() -> audit_log_n_string(), which
                      # surrounds every control-char-free string with '"' (kernel/audit.c,
                      # documented in audit_log_n_untrustedstring's comment). ausearch
                      # --raw passes that through untouched, so the journal says
                      # key="mount" - an unquoted key= regex matches nothing, ever.
                      # sops-access deliberately NOT here: it now fires on every routine
                      # secret READ (each service boot), so it got its own alert below.
                      expr = ''count(sum by (host) (count_over_time({unit="audit-forward"} |~ `key="(mount|modules|ptrace|kernel|secret-access|jail-break)` [$__auto]))) > 0'';
                      queryType = "range";
                    };
                  }
                  {
                    refId = "C";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "__expr__";
                    model = {
                      type = "threshold";
                      conditions = [
                        {
                          evaluator = {
                            type = "gt";
                            params = [0];
                          };
                          operator.type = "and";
                          query.params = ["A"];
                        }
                      ];
                    };
                  }
                ];
                noDataState = "OK";
                execErrState = "Error";
                for = "0m";
                labels = {
                  severity = "critical";
                  team = "home";
                };
                annotations = {
                  summary = "auditd caught a stop-do-everything syscall key; run: sudo ausearch -k <key> --start today";
                };
              }
              {
                # The sops-access sibling, split out on purpose: per-secret read-watches
                # make every legitimate service boot log key="sops-access" opens. Same
                # spine, warning severity, so restart storms page *quietly* while an
                # out-of-boot-window secret read still surfaces.
                uid = "audit-secret-reads";
                title = "Audit: secret files read (sops-access - normal at service boot, odd otherwise)";
                condition = "C";
                data = [
                  {
                    refId = "A";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "loki";
                    model = {
                      expr = ''sum by (host) (count_over_time({unit="audit-forward"} |~ `key="sops-access` [$__auto])) > 0'';
                      queryType = "range";
                    };
                  }
                  {
                    refId = "C";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "__expr__";
                    model = {
                      type = "threshold";
                      conditions = [
                        {
                          evaluator = {
                            type = "gt";
                            params = [0];
                          };
                          operator.type = "and";
                          query.params = ["A"];
                        }
                      ];
                    };
                  }
                ];
                noDataState = "OK";
                execErrState = "Error";
                for = "0m";
                labels = {
                  severity = "warning";
                  team = "home";
                };
                annotations = {
                  summary = "a secret under /run/secrets or /run/jail-secrets was opened (key=sops-access); run: sudo ausearch -k sops-access --start today | grep -v exe=\\\"/nix/store\"";
                };
              }
              {
                uid = "audit-egress-deny";
                title = "Firewall: jail egress deny logged (blocked lateral move attempt)";
                condition = "C";
                data = [
                  {
                    refId = "A";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "loki";
                    model = {
                      expr = ''sum by (host) (count_over_time({job="systemd-journal"} |= `egress-deny-` [$__auto])) > 0'';
                      queryType = "range";
                    };
                  }
                  {
                    refId = "C";
                    relativeTimeRange.from = 300;
                    to = 0;
                    datasourceUid = "__expr__";
                    model = {
                      type = "threshold";
                      conditions = [
                        {
                          evaluator = {
                            type = "gt";
                            params = [0];
                          };
                          operator.type = "and";
                          query.params = ["A"];
                        }
                      ];
                    };
                  }
                ];
                noDataState = "OK";
                execErrState = "Error";
                for = "0m";
                labels = {
                  severity = "warning";
                  team = "home";
                };
                annotations = {
                  summary = "a jailed uid tried to reach a blocked network (journald carries the LOGGED rule with prefix egress-deny-<jail>: )";
                };
              }
              # TODO(§3.3): the svc-exec allowlist rule needs one clean week of data to seed
              # the known exe= set per user before it stops being noise; until then query
              # Loki with {unit="audit-forward"} |= "svc-exec-" by hand after any incident.
            ];
          }
        ];
      };
    })
  ];
}
