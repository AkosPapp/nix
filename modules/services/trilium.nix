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

    litellm = {
      enable = mkEnableOption ''
        LiteLLM as a pre-seeded AI provider in Trilium's Settings -> AI. ETAPI cannot touch
        options in v0.106 (there is no /etapi/options route), and the provider list lives in the
        synced `llmProviders` option (a JSON array in the options table of document.db), so this
        writes it with sqlite directly - in a pre-stop step of trilium.service, while the
        container is down and Becca (Trilium's in-memory cache) cannot clobber it. It seeds once:
        the row `triliumNixSeeded` marks the instance as handled, so edits made in the UI after
        the first start survive reboots (delete that options row to let it seed again).

        The key is a dedicated LiteLLM virtual key (created from the master key with
        `curl -H "Authorization: Bearer $(cat /run/secrets/litellm_master_key)"
        http://127.0.0.1:8095/key/generate -d '{"key_alias": "trilium"}'`, the `key` of the
        response going to sops as the secret named below) - not the master key: it goes into
        document.db in plain text (that is how Trilium stores provider keys), so anything that
        can read the data dir gets this key, and it should be a scoped one.
      '';

      apiTokenSecret = mkOption {
        type = types.str;
        default = "trilium/litellm_api_key";
        description = "sops secret holding the LiteLLM virtual key for Trilium.";
      };

      baseURL = mkOption {
        type = types.str;
        default = "http://127.0.0.1:${toString config.PORTS.litellm}/v1";
        description = ''
          The OpenAI-compatible endpoint Trilium will call. Loopback by default: the container
          shares the host network (see extraOptions), so this reaches this host's own LiteLLM -
          point it at https://litellm.hp to route through Traefik instead.
        '';
      };

      models = mkOption {
        type = types.listOf types.str;
        default = ["futurelab/qwen3.8-flash-next"];
        description = ''
          LiteLLM model names to preselect as the provider's chat models; the first is marked
          default. They are denormalized into the config for the UI's picker (that is what
          selectedModels means here), so a wrong name shows up as a dead option rather than
          failing anywhere until it is actually chatted with.
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
        # Keeps the unit at trilium.service, like litellm.nix and omniroute.nix.
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

    (mkIf (cfg.enable && cfg.litellm.enable) (let
      seedScript = pkgs.writeShellScript "trilium-seed-litellm" ''
        set -eu
        db=${dataDir}/document.db
        # First boot until the browser setup ran: no DB to seed into (the next stop covers it).
        [ -e "$db" ] || exit 0
        # Seed exactly once: an untouched provider list and no seed marker. Anything else (the UI
        # has been used since, or it is already seeded) is left alone.
        todo=$(${pkgs.sqlite}/bin/sqlite3 "$db" "SELECT CASE WHEN EXISTS (SELECT 1 FROM options WHERE name = 'llmProviders' AND value = '[]') AND NOT EXISTS (SELECT 1 FROM options WHERE name = 'triliumNixSeeded') THEN 1 ELSE 0 END;")
        [ "$todo" = "1" ] || exit 0
        ${pkgs.sqlite}/bin/sqlite3 "$db" "INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('llmProviders', CAST(readfile('${config.sops.templates."trilium-llm-providers.json".path}') AS TEXT), 1, strftime('%Y-%m-%d %H:%M:%S', 'now')); INSERT OR REPLACE INTO options (name, value, isSynced, utcDateModified) VALUES ('triliumNixSeeded', '1', 0, strftime('%Y-%m-%d %H:%M:%S', 'now'));"
        # The sqlite3 client ran as root; hand the DB back to the uid the container writes as.
        chown 1000:1000 "$db" "$db"-wal "$db"-shm 2>/dev/null || true
      '';
    in {
      assertions = [
        {
          assertion = config.MODULES.services.litellm.enable;
          message = ''
            MODULES.services.trilium.litellm.enable needs MODULES.services.litellm on the same
            host - it points Trilium's provider at this host's LiteLLM.
          '';
        }
      ];

      sops.secrets.${cfg.litellm.apiTokenSecret} = {};

      # The provider list as Trilium will find it in the options table. The placeholder (unlike
      # the sqlite write itself, which cannot expand anything) is substituted by sops at
      # activation, so the real key appears only in this root-readable runtime file - and, once
      # seeded, in document.db, which is the app's own storage and its own exposure.
      sops.templates."trilium-llm-providers.json" = {
        mode = "0400";
        content = builtins.toJSON [
          {
            id = "litellm";
            name = "LiteLLM";
            provider = "openai-compatible";
            kind = "llm";
            apiKey = config.sops.placeholder.${cfg.litellm.apiTokenSecret};
            baseURL = cfg.litellm.baseURL;
            selectedModels =
              lib.imap0 (i: m: {
                id = m;
                name = m;
                provider = "openai-compatible";
                providerId = "litellm";
                providerName = "LiteLLM";
                isDefault = i == 0;
              })
              cfg.litellm.models;
          }
        ];
      };

      # Runs after the container stopped (unit ExecStopPost fires on every stop/restart, and
      # mkAfter puts this one behind the oci-containers' own post-stop): the DB is then closed,
      # so Trilium reads the seeded option into Becca on the next start instead of overwriting
      # it from its cache.
      systemd.services.trilium.serviceConfig.ExecStopPost = lib.mkAfter ["+${seedScript}"];
    }))
  ];
}
