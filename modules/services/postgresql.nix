# One hardened pg_hba for the whole fleet (PLAN.md §2.1), replacing nixpkgs' defaults of
# `local all all peer` + `host all all 127.0.0.1/32 md5`:
#
#   - "local all all peer" sounds safe but grants every OS user a lane: anyone whose uid has a
#     same-named DB role can walk in, and a service user added later can silently match a role
#     nobody meant to expose. Here every socket path is an explicit line; anything else must
#     present a scram-sha-256 password that exists for no default role.
#   - "md5" on the TCP lines is the retired HMAC-MD5 scheme; the fleet's TCP clients (MAS,
#     roundcube) already know plaintext passwords, so switching the method (and re-hashing the
#     role, which happens at their setup units) costs nothing and gets SCRAM both ways.
#
# Consumers declare their access:
#   socketPeerRoles  - same-named OS user and role over the unix socket (the default for
#                      firefly-iii, matrix-synapse);
#   identMaps        - a system user that is NOT named after the role (a container that runs as
#                      root but connects with its own role, like the old LiteLLM one, needs a map
#                      entry, still scoped to one database).
# A host that enables postgresql without this module keeps nixpkgs' loose defaults - the
# assertion below is there to make that a build error on hosts that have a database at all.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption mkForce types;

  cfg = config.MODULES.services.postgres;
in {
  options.MODULES.services.postgres = {
    enable = mkEnableOption ''
      the fleet's hardened PostgreSQL host-based authentication (PLAN.md §2.1): explicit peer
      lines only on the unix socket, scram-sha-256 everywhere else, TCP restricted to loopback.
      Declare each service's access via socketPeerRoles / identMaps.
    '';

    socketPeerRoles = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [
        "matrix-synapse"
        "firefly-iii"
      ];
      description = ''
        Database roles allowed to connect over the unix socket as the same-named OS user
        (peer authentication). Only meaningful when the app's system user and its role share
        a name, which is the convention this repo already follows.
      '';
    };

    identMaps = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Name of the ident map entry.";
          };
          systemUser = mkOption {
            type = types.str;
            description = "The OS uid that connects (e.g. root, for a container).";
          };
          database = mkOption {
            type = types.str;
            description = "The one database the map entry can reach.";
          };
          role = mkOption {
            type = types.str;
            description = "The database role it is mapped to.";
          };
        };
      });
      default = [];
      example = [
        {
          name = "paperless";
          systemUser = "root";
          database = "paperless";
          role = "paperless";
        }
      ];
      description = "System-user-to-role mappings, each still scoped to a single database.";
    };

    preloadLibraries = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["vchord.so"];
      description = ''
        shared_preload_libraries for this host's Postgres. Consumers declare their entry
        here (immich: vchord.so; corootIntegration adds pg_stat_statements) - the module
        owns the settings leaf and mkForce's it, because nixpkgs' immich module defines the
        same leaf with a plain list and two plain definitions of one option is an eval
        error. Declare preload HERE, not on services.postgresql.settings.
      '';
    };

    corootIntegration = {
      enable = mkEnableOption ''
        Coroot's Postgres integration on this host's server (PLAN §4): a login role with
        pg_monitor, pg_stat_statements in every database, and the preload entry - all
        provisioned by a oneshot as the postgres user. The password lives in the sops
        passwordSecret below and goes into Coroot's per-app "Configure Postgres
        integration" form (port 5432, this role); the hardened pg_hba's loopback
        scram-sha-256 lines already admit it, nothing opens beyond loopback.
      '';

      role = mkOption {
        type = types.strMatching "[a-z_][a-z0-9_]*";
        default = "coroot";
        description = ''
          Login role Coroot connects as. Also gets a same-named database: pq-style clients
          default dbname to the username, and without it that first connect fails outright.
          Interpolated into SQL, hence the charset type.
        '';
      };

      passwordSecret = mkOption {
        type = types.str;
        default = "coroot/postgres_password";
        description = "sops secret holding the role's password (installed 0400, owned by postgres).";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.postgresql.enable;
        message = ''
          MODULES.services.postgres.enable is set but services.postgresql.enable is not -
          the hardened pg_hba has no server to install it into.
        '';
      }
      {
        assertion = (builtins.length (builtins.catAttrs "name" cfg.identMaps)) == (lib.length (lib.unique (builtins.catAttrs "name" cfg.identMaps)));
        message = "MODULES.services.postgres.identMaps contains duplicate map names.";
      }
    ];

    services.postgresql.identMap =
      lib.concatMapStrings (m: ''
        ${m.name} ${m.systemUser} ${m.role}
      '')
      cfg.identMaps;

    # mkForce: the point is to replace nixpkgs' trailing defaults, which arrive via mkAfter and
    # would otherwise sit below and still match first-few users (postgres's own map line is
    # re-added verbatim; identMap's default "postgres postgres postgres" line stays via mkAfter).
    services.postgresql.authentication = mkForce (
      lib.concatStringsSep "" (
        [
          ''
            # Generated by MODULES.services.postgres - see modules/services/postgresql.nix.
            local   all       postgres            peer map=postgres
          ''
        ]
        ++ map (r: "local   ${r}  ${r}  peer\n") cfg.socketPeerRoles
        ++ map (m: "local   ${m.database}  ${m.role}  peer map=${m.name}\n") cfg.identMaps
        ++ [
          ''
            local   all       all                 scram-sha-256
            host    all       all     127.0.0.1/32  scram-sha-256
            host    all       all     ::1/128       scram-sha-256
          ''
        ]
      )
    );

    # Own the preload leaf (see MODULES.services.postgres.preloadLibraries' description):
    # mkForce beats nixpkgs-immich's plain definition of the same option instead of
    # colliding with it; skipped when the host declares nothing, so hosts without a
    # preload need keep whatever nixpkgs wires by default.
    services.postgresql.settings.shared_preload_libraries = mkIf (cfg.preloadLibraries != []) (
      mkForce (
        lib.unique
        (cfg.preloadLibraries ++ lib.optionals cfg.corootIntegration.enable ["pg_stat_statements"])
      )
    );

    # ---- Coroot Postgres integration (option description above) ------------------------------
    sops.secrets.${cfg.corootIntegration.passwordSecret} = mkIf cfg.corootIntegration.enable {
      owner = "postgres";
      mode = "0400";
    };

    # The unit runs as the postgres OS user, so the hardened pg_hba's first line
    # (`local all postgres peer map=postgres`) admits it over the socket - no extra rule,
    # and the role it creates can only ever reach the cluster through the loopback scram
    # lines like every other TCP client. Idempotent (IF NOT EXISTS / ALTER / GRANT), so a
    # re-run after rotating the sops password is the whole story:
    #   systemctl restart coroot-postgres-setup
    # hp/akos01 2026-10-27: Coroot's RCA kept showing "It seems this app is a Postgres
    # database... Configure integration" for every app touching 5432 because nothing was
    # provisioned anywhere in the fleet.
    systemd.services.coroot-postgres-setup = mkIf cfg.corootIntegration.enable {
      description = "Provision Coroot's Postgres monitoring role and pg_stat_statements";
      after = ["postgresql.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "coroot-postgres-setup" ''
          set -euo pipefail
          psql=${config.services.postgresql.package}/bin/psql
          # Quoted heredoc: the shell must not eat $$ (psql-side DO block) or :'pw'
          # (psql variable, carries the password WITHOUT it ever touching argv).
          "$psql" -v ON_ERROR_STOP=1 -v pw="$(< ${config.sops.secrets.${cfg.corootIntegration.passwordSecret}.path})" <<'SQL'
          DO $$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${cfg.corootIntegration.role}') THEN
              CREATE ROLE ${cfg.corootIntegration.role} LOGIN;
            ELSE
              ALTER ROLE ${cfg.corootIntegration.role} LOGIN;
            END IF;
          END $$;
          ALTER ROLE ${cfg.corootIntegration.role} PASSWORD :'pw';
          GRANT pg_monitor TO ${cfg.corootIntegration.role};
          SELECT 'CREATE DATABASE ${cfg.corootIntegration.role} OWNER ${cfg.corootIntegration.role}'
          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${cfg.corootIntegration.role}')\gexec
          SQL
          # pg_stat_statements is per-database; Coroot may connect to any of them, and
          # template1 included means freshly created DBs arrive statement-ready.
          for db in $("$psql" -Atc "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0'"); do
            "$psql" -d "$db" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
          done
        '';
      };
    };
  };
}
