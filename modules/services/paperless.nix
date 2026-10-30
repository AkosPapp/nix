{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkAfter mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.MODULES.services.paperless;
  hermesModule = config.MODULES.services.hermes-agent;

  dataDir = "/var/lib/paperless";
  # USERMAP_UID/USERMAP_GID, rewritten by the ExecStartPre below right before every
  # `docker run` (the oci-containers unit runs `docker run`, not `docker start`, so the
  # file is re-read on every start/restart). Same mechanism as joplin.nix's container.env.
  envFile = "${dataDir}/container.env";

  containerEnvScript = pkgs.writeShellScript "paperless-container-env" ''
    set -eu
    # The ids resolve HERE, at unit start: `paperless` is a system user whose numeric ids
    # nixpkgs allocates at activation, so they are not knowable at eval time. Re-resolved
    # on every start, so a uid churn is never baked into a running container. The image's
    # s6 init remaps its own `paperless` user to these (init-modify-user) and every
    # service then runs as that uid, so the bind mounts below carry one honest owner on
    # the host instead of the image's default 1000 - which is some unrelated host user.
    {
      echo "USERMAP_UID=$(${pkgs.coreutils}/bin/id -u paperless)"
      echo "USERMAP_GID=$(${pkgs.coreutils}/bin/id -g paperless)"
    } > ${envFile}
    ${pkgs.coreutils}/bin/chmod 0400 ${envFile}
  '';
in {
  options.MODULES.services.paperless = {
    enable = mkEnableOption ''
      paperless-ngx (https://paperless-ngx.com), the self-hosted document archive:
      https://paperless.<host> on the tailnet (loopback container behind Traefik, like
      trilium.nix). Hermes reaches it the Trilium way - over the REST API with a token
      (`apiTokenSecret`), not over files: documents go in through POST /api/post_document
      and come back out through /api/download/<id>/, so nothing of the archive lives
      inside the hermes state dir. The v3 image no longer bundles its database and broker
      (the all-in-one supervisord era is over; the official compose files are split), so
      this is two containers: the app on sqlite plus a valkey broker, both loopback-only
      on the host network.
    '';

    image = mkOption {
      type = types.str;
      default = "ghcr.io/paperless-ngx/paperless-ngx:3.4.0";
      description = ''
        Container image, pinned to the release that is `latest` on the registry at the
        time of writing (v3.4.0, tagged without the v prefix unlike the GitHub release).
        Bumping the tag is the upgrade path; paperless applies its own Django migrations
        on start (the data dir bind mount is the thing to keep - and before a major
        bump, document_exporter: the znapzend snapshots cover it, a downgrade does not).
      '';
    };

    brokerImage = mkOption {
      type = types.str;
      default = "docker.io/valkey/valkey:9-alpine";
      description = ''
        The celery broker image - the same tag the project's own reference compose files
        run. Valkey, not `redis`: the upstream compose moved when the Redis license did.
      '';
    };

    ocrLanguages = mkOption {
      type = types.listOf types.str;
      default = ["eng" "deu"];
      description = ''
        Languages passed to PAPERLESS_OCR_LANGUAGE (joined with "+"). Same default the
        hermes-agent tool set ships for tesseract; a document scanned in a language that
        is not listed here OCRs to empty text and stays unsearchable forever, so this is
        a policy list, not a tuning knob.
      '';
    };

    timeZone = mkOption {
      type = types.str;
      default = config.time.timeZone;
      defaultText = lib.literalExpression "config.time.timeZone";
      description = ''
        PAPERLESS_TIME_ZONE. The docker default is UTC and date-stamps receipts against
        it; the host's own zone is what the documents were signed in.
      '';
    };

    consumeDir = mkOption {
      type = types.str;
      default = "${dataDir}/consume";
      description = ''
        The hot folder: drop a scanned PDF in (mounted at /usr/src/paperless/consume)
        and the consumer files it. Deliberately NOT inside the hermes state dir -
        Hermes is a paperless API client (see `apiTokenSecret`), not a neighbour with a
        bind of this tree; the API upload carries ownership and permissions with it.
      '';
    };

    apiTokenSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "paperless/api_token";
      description = ''
        sops secret holding a paperless API token for Hermes. Manual one-time steps
        (the archive needs a human superuser before anything works, like trilium.nix's
        ETAPI token): open https://paperless.<host>, create the superuser on the
        first-run page, then mint the token

            docker exec -u paperless paperless python3 manage.py drf_create_token <username>

        (or in the UI: Administration -> Auth tokens) and store it with

            sops set sops/secrets.yaml '["paperless"]["api_token"]' --value-stdin <<< '"<token>"'

        and set this option. Hermes then gets PAPERLESS_API_URL
        (http://127.0.0.1:<port>/api/) and PAPERLESS_API_TOKEN in its env file, its
        egress filter gains the loopback port, and it can search, file and fetch
        documents with plain curl (`Authorization: Token <key>`; GET
        /api/documents/?query=..., POST /api/post_document,
        see https://docs.paperless-ngx.com/api/). Until it is set paperless runs but
        Hermes cannot touch it. The token inherits its user's view - create it for a
        dedicated least-privilege account if Hermes should not see every document.
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";

      users.groups.paperless = {};
      users.users.paperless = {
        isSystemUser = true;
        group = "paperless";
        home = dataDir;
      };

      systemd.tmpfiles.rules = [
        # container.env lives in the parent, hence root's own 0700 like the siblings;
        # the app trees belong to the user the container remaps to.
        "d ${dataDir} 0700 root root - -"
        "d ${dataDir}/data 0750 paperless paperless - -"
        "d ${dataDir}/media 0750 paperless paperless - -"
        "d ${cfg.consumeDir} 0750 paperless paperless - -"
      ];

      virtualisation.oci-containers.containers.paperless-broker = {
        image = cfg.brokerImage;
        # Keeps the unit at paperless-broker.service, like the sibling modules pin theirs.
        serviceName = "paperless-broker";

        # valkey binds 0.0.0.0:6379 by default; on --network=host that would be THIS
        # host's port on every interface. Name loopback and our PORTS slot instead.
        cmd = [
          "--bind"
          "127.0.0.1"
          "--port"
          (toString config.PORTS.paperlessBroker)
          # No persistence: only undelivered celery tasks live here, and the consumer
          # re-scans the consume dir at start. No volume, so also no host-side ownership
          # story for the image's valkey uid to write into.
          "--save"
          ""
        ];

        extraOptions = ["--network=host"];
      };

      virtualisation.oci-containers.containers.paperless = {
        inherit (cfg) image;
        # Keeps the unit at paperless.service, like litellm.nix/omniroute.nix/trilium.nix.
        serviceName = "paperless";

        dependsOn = ["paperless-broker"];

        volumes = [
          "${dataDir}/data:/usr/src/paperless/data"
          "${dataDir}/media:/usr/src/paperless/media"
          "${cfg.consumeDir}:/usr/src/paperless/consume"
        ];

        environment = {
          PAPERLESS_PORT = toString config.PORTS.paperless;
          # sqlite in the data dir (the image's own default, stated so the choice is
          # visible): one archive on one host, and it keeps the whole DB inside the
          # dataset znapzend snapshots. Postgres would mean a third container AND a
          # fight with this host's own cluster for 5432.
          PAPERLESS_DBENGINE = "sqlite";
          PAPERLESS_REDIS = "redis://127.0.0.1:${toString config.PORTS.paperlessBroker}";
          # The webserver (granian) binds "::" unless told otherwise; loopback like
          # every sibling container behind Traefik. Even if the image ignored it, the
          # firewall opens the port nowhere - do not lean on that.
          PAPERLESS_BIND_ADDR = "127.0.0.1";
          PAPERLESS_URL = config.MODULES.networking.traefik.urlOf "paperless";
          PAPERLESS_TIME_ZONE = cfg.timeZone;
          PAPERLESS_OCR_LANGUAGE = builtins.concatStringsSep "+" cfg.ocrLanguages;
        };

        environmentFiles = [envFile];

        # Host networking like omniroute/trilium/joplin (loopback binds need no published
        # port). No --user: the s6 init must start as root to remap the image's paperless
        # user to the host ids in container.env and to fix the bind mounts' ownership;
        # every service then drops privileges itself (s6-setuidgid paperless), so unlike
        # the root-behind `--user=0:0` containers there IS a stable host uid behind the
        # processes - which is why the jail.nix row can already name it.
        extraOptions = ["--network=host"];
      };

      # mkAfter puts this behind the module's own pre-start; ExecStartPre runs before the
      # unit's `docker run`, so the file exists on the very first start.
      systemd.services.paperless.serviceConfig.ExecStartPre = mkAfter ["+${containerEnvScript}"];

      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.services.paperless = "127.0.0.1:${toString config.PORTS.paperless}";
    })

    (mkIf (cfg.enable && cfg.apiTokenSecret != null) {
      assertions = [
        {
          assertion = hermesModule.enable;
          message = ''
            MODULES.services.paperless.apiTokenSecret is set but MODULES.services.hermes-agent is
            not enabled on this host - there is nobody to hand the token to.
          '';
        }
      ];

      sops.secrets.${cfg.apiTokenSecret} = {};

      MODULES.services.hermes-agent.extraAllowedLoopbackPorts = [config.PORTS.paperless];

      # Appended to hermes-agent.nix's env template: mkAfter is string concatenation, so
      # both modules contribute lines and sops substitutes the token at activation (the
      # trilium.nix ETAPI wiring, verbatim in shape).
      sops.templates."hermes.env".content = mkAfter ''
        PAPERLESS_API_URL=http://127.0.0.1:${toString config.PORTS.paperless}/api/
        PAPERLESS_API_TOKEN=${config.sops.placeholder.${cfg.apiTokenSecret}}
      '';
    })
  ];
}
