{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkAfter mkEnableOption mkIf mkOption mkMerge types;

  cfg = config.MODULES.services.trilium;
  hermesModule = config.MODULES.services.hermes-agent;

  dataDir = "/var/lib/trilium";
in {
  options.MODULES.services.trilium = {
    enable = mkEnableOption ''
      Trilium Notes (TriliumNext), a hierarchical knowledge-base note app: https://trilium.<host>
      on the tailnet (loopback container behind Traefik, like omniroute.nix). Hermes edits the same
      notes through Trilium's ETAPI REST interface once `etapiTokenSecret` is filled in (see its
      description for the one-time manual step)
    '';

    image = mkOption {
      type = types.str;
      default = "triliumnext/trilium:v0.106.0";
      description = ''
        Container image, pinned to the release that is `latest`/`stable` on Docker Hub at the time
        of writing. Bumping the tag is the upgrade path; Trilium applies its own DB migrations on
        start (the data dir bind mount is the thing to keep).
      '';
    };

    gateway = {
      enable = mkEnableOption ''
        the fleet gateway (OmniRoute) as a pre-seeded AI provider in Trilium's
        Settings -> AI. ETAPI cannot touch options in v0.106 (there is no
        /etapi/options route), and the provider list lives in the synced
        `llmProviders` option (a JSON array in the options table of document.db), so this
        writes it with sqlite directly - in a pre-stop step of trilium.service, while the
        container is down and Becca (Trilium's in-memory cache) cannot clobber it. It seeds
        once: the row `triliumNixSeeded` marks the instance as handled, so edits made in the
        UI after the first start survive reboots (delete that options row to let it seed
        again). (Was `litellm` until phase 3, 2026-11-09.)

        The key goes into document.db in plain text (that is how Trilium stores provider
        keys), so anything that can read the data dir gets it - a dedicated inference key
        minted on the OmniRoute dashboard (API Keys page, scoped/capped there) is the
        cheap scoping step whenever wanted; see apiTokenSecret.
      '';

      apiTokenSecret = mkOption {
        type = types.str;
        default = "omniroute_api_key";
        example = "trilium/omniroute_api_key";
        description = ''
          sops secret holding the OmniRoute inference key for Trilium. Defaults to the
          shared fleet harness key so the enable is self-contained; because it lands in
          document.db unencrypted, a dedicated dashboard-minted key under its own sops
          name (example) is the scoped choice - the old trilium/litellm_api_key value is
          a LiteLLM key and 401s here. IGNORED when `apiTokenFile` is set (audit #7,
          2026-11-14: the nix-minted per-service key wins and the sops mount is
          dropped).
        '';
      };

      apiTokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression "config.MODULES.services.omniroute.keys.trilium.filePath";
        description = ''
          Path to the file holding the raw OmniRoute inference key for Trilium; on the
          gateway host this is a nix-minted per-service key (MODULES.services.omniroute.keys
          - audit #7; the seed unit reads it ROOT-SIDE while writing document.db, exactly
          like the sops mount today, so the raw filePath with owner root is the right one -
          Trilium itself never sees the file). null (default) = the apiTokenSecret sops
          behavior, unchanged. Seed-once caveat inherited from the sops path: a RE-MINTED
          value lands in document.db only on a fresh seed - after a rotation clear the
          llmProviders row (or fix the key under Trilium's Settings -> AI) so the next
          stop re-seeds.
        '';
      };

      baseURL = mkOption {
        type = types.str;
        default = "http://127.0.0.1:${toString config.PORTS.omniroute}/v1";
        description = ''
          The OpenAI-compatible endpoint Trilium will call. Loopback by default: the container
          shares the host network (see extraOptions), so this reaches this host's own
          gateway - point it at https://omniroute.hp to route through Traefik instead.
        '';
      };

      models = mkOption {
        type = types.listOf types.str;
        default = ["futurelab/qwen3.8-flash-next"];
        description = ''
          Gateway model ids (connection-prefixed, the spelling /v1/models answers with)
          to preselect as the provider's chat models; the first is marked default. They
          are denormalized into the config for the UI's picker (that is what
          selectedModels means here), so a wrong name shows up as a dead option rather
          than failing anywhere until it is actually chatted with.
        '';
      };
    };

    etapiTokenSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "trilium/etapi_token";
      description = ''
        sops secret holding an ETAPI token for Hermes. Manual one-time step (nothing can mint one
        before a human has logged in): open
        https://trilium.<host>, set the login password, then Settings -> ETAPI -> "New token"
        (sync=false is enough for loopback use) and store it with

            sops set sops/secrets.yaml '["trilium"]["etapi_token"]' --value-stdin <<< '"<token>"'

        and set this option. Hermes then gets TRILIUM_ETAPI_URL (http://127.0.0.1:<port>/etapi)
        and TRILIUM_ETAPI_TOKEN in its env file, its egress filter gains the loopback port, and
        it can read and write notes with plain curl (POST /etapi/notes, PATCH /etapi/branches/...,
        see https://triliumnext.github.io/Docs/ETAPI). Until it is set Trilium runs but Hermes
        cannot touch it.
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";

      systemd.tmpfiles.rules = [
        "d ${dataDir} 0700 root root - -"
      ];

      virtualisation.oci-containers.containers.trilium = {
        inherit (cfg) image;
        # Keeps the unit at trilium.service, like omniroute.nix.
        serviceName = "trilium";

        volumes = ["${dataDir}:/home/node/trilium-data"];

        environment = {
          TRILIUM_DATA_DIR = "/home/node/trilium-data";
          TRILIUM_PORT = toString config.PORTS.trilium;
          # Loopback: Traefik (and Hermes via the ETAPI port hole) are the only expected clients.
          # Even if the image ignored this and bound 0.0.0.0, the host firewall still drops the
          # port - it is opened nowhere - but do not lean on that.
          TRILIUM_HOST = "127.0.0.1";
        };

        # Host networking like omniroute.nix (loopback bind needs no published port) and --user=0:0
        # for the same reason: the image's uid 1000 cannot write the root-owned 0700 bind mount.
        extraOptions = ["--network=host" "--user=0:0"];
      };

      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.services.trilium = "127.0.0.1:${toString config.PORTS.trilium}";
    })

    (mkIf (cfg.enable && cfg.etapiTokenSecret != null) {
      assertions = [
        {
          assertion = hermesModule.enable;
          message = ''
            MODULES.services.trilium.etapiTokenSecret is set but MODULES.services.hermes-agent is
            not enabled on this host - there is nobody to hand the token to.
          '';
        }
      ];

      sops.secrets.${cfg.etapiTokenSecret} = {};

      MODULES.services.hermes-agent.extraAllowedLoopbackPorts = [config.PORTS.trilium];

      # Appended to hermes-agent.nix's env template: mkAfter is string concatenation, so both
      # modules contribute lines and sops substitutes the token at activation (same mechanism as
      # LITELLM_API_KEY there).
      sops.templates."hermes.env".content = mkAfter ''
        TRILIUM_ETAPI_URL=http://127.0.0.1:${toString config.PORTS.trilium}/etapi
        TRILIUM_ETAPI_TOKEN=${config.sops.placeholder.${cfg.etapiTokenSecret}}
      '';
    })

    (mkIf (cfg.enable && cfg.gateway.enable) (let
      # The provider row's SHAPE (everything but the key) is defined once; the key is
      # injected at seed time from whichever source the options name (Rule 2 - the sops
      # template and the file-source seed below describe one provider).
      providerRow = {
        id = "omniroute";
        name = "OmniRoute";
        provider = "openai-compatible";
        kind = "llm";
        baseURL = cfg.gateway.baseURL;
        selectedModels =
          lib.imap0 (i: m: {
            id = m;
            name = m;
            provider = "openai-compatible";
            providerId = "omniroute";
            providerName = "OmniRoute";
            isDefault = i == 0;
          })
          cfg.gateway.models;
      };
      # File source only: the key-less provider list, the seed script merges the minted
      # key in with jq at stop time (the store copy never carries a secret).
      providerRowJson = pkgs.writeText "trilium-llm-providers-row.json" (builtins.toJSON [providerRow]);
      seedScript = pkgs.writeShellScript "trilium-seed-gateway" (''
          set -eu
          db=${dataDir}/document.db
          # First boot until the browser setup ran: no DB to seed into (the next stop covers it).
          [ -e "$db" ] || exit 0
          # Seed once (untouched list, no marker) OR re-seed exactly when a still-`litellm`-id'd
          # provider is present - the phase-3 migration (2026-11-09, litellm.nix deleted): hp's
          # document.db carries the old seeded entry, and without this the once-semantics would
          # leave Trilium's AI pointed at a stopped gateway. The new content contains no
          # providerId "litellm", so this converges; any OTHER state (user edits after seeding,
          # other providers they added) is left alone exactly as before.
          todo=$(${pkgs.sqlite}/bin/sqlite3 "$db" "SELECT CASE WHEN (EXISTS (SELECT 1 FROM options WHERE name = 'llmProviders' AND value = '[]') AND NOT EXISTS (SELECT 1 FROM options WHERE name = 'triliumNixSeeded')) OR EXISTS (SELECT 1 FROM options WHERE name = 'llmProviders' AND value LIKE '%\"providerId\":\"litellm\"%') THEN 1 ELSE 0 END;")
          [ "$todo" = "1" ] || exit 0
        ''
        + (
          if cfg.gateway.apiTokenFile != null
          then ''
            # File source (audit #7, 2026-11-14): the nix-minted key read ROOT-SIDE here (this
            # ExecStopPost runs as +root for the chown below) - Trilium itself never sees the
            # file, and the value lands in document.db exactly like the sops path's. jq keeps
            # the key out of every argv (a /proc-visible sqlite3 -c string would leak it to
            # all local processes mid-seed). A missing/unreadable file fails the stop loudly:
            # the omniroute seed unit owns minting it; stop trilium again after the switch
            # that minted it (seed-once semantics, see apiTokenFile).
            tmpj=$(mktemp)
            trap 'rm -f "$tmpj"' EXIT
            ${pkgs.jq}/bin/jq --rawfile key ${cfg.gateway.apiTokenFile} \
              'map(.apiKey = ($key | rtrimstr("\n")))' ${providerRowJson} > "$tmpj"
            ${pkgs.sqlite}/bin/sqlite3 "$db" "INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('llmProviders', CAST(readfile('$tmpj') AS TEXT), 1, strftime('%Y-%m-%d %H:%M:%S', 'now')); INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('triliumNixSeeded', '1', 0, strftime('%Y-%m-%d %H:%M:%S', 'now'));"
          ''
          else ''
            ${pkgs.sqlite}/bin/sqlite3 "$db" "INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('llmProviders', CAST(readfile('${config.sops.templates."trilium-llm-providers.json".path}') AS TEXT), 1, strftime('%Y-%m-%d %H:%M:%S', 'now')); INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('triliumNixSeeded', '1', 0, strftime('%Y-%m-%d %H:%M:%S', 'now'));"
          ''
        )
        + ''
          # The sqlite3 client ran as root; hand the DB back to the uid the container writes as.
          chown 1000:1000 "$db" "$db"-wal "$db"-shm 2>/dev/null || true
        '');
    in {
      assertions = [
        {
          assertion = config.MODULES.services.omniroute.enable;
          message = ''
            MODULES.services.trilium.gateway.enable needs MODULES.services.omniroute on the same
            host - it points Trilium's provider at this host's gateway.
          '';
        }
      ];

      sops.secrets.${cfg.gateway.apiTokenSecret} = mkIf (cfg.gateway.apiTokenFile == null) {};

      # The provider list as Trilium will find it in the options table (sops source only;
      # the file source injects the key at seed time in the script above instead, because a
      # placeholder template cannot reference a file that may not exist at activation). The
      # placeholder (unlike the sqlite write itself, which cannot expand anything) is
      # substituted by sops at activation, so the real key appears only in this
      # root-readable runtime file - and, once seeded, in document.db, which is the app's
      # own storage and its own exposure.
      sops.templates."trilium-llm-providers.json" = mkIf (cfg.gateway.apiTokenFile == null) {
        mode = "0400";
        content = builtins.toJSON [(providerRow // {apiKey = config.sops.placeholder.${cfg.gateway.apiTokenSecret};})];
      };

      # Runs after the container stopped (unit ExecStopPost fires on every stop/restart, and
      # mkAfter puts this one behind the oci-containers' own post-stop): the DB is then closed,
      # so Trilium reads the seeded option into Becca on the next start instead of overwriting
      # it from its cache.
      systemd.services.trilium.serviceConfig.ExecStopPost = lib.mkAfter ["+${seedScript}"];
    }))
  ];
}
