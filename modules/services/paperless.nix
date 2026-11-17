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

  # v3 made PAPERLESS_SECRET_KEY mandatory: with the image default it aborts init-migrations
  # ("ImproperlyConfigured: PAPERLESS_SECRET_KEY is not set or is the default 'change-me'
  # value", hp 2026-10-31 00:13 - s6 treats a failed init as fatal, so the container
  # crash-looped). It signs cookies and tokens, so it must be STABLE - generated once on
  # the host and persisted next to the data it signs (znapzend snapshots cover both; a
  # restore that pairs data with a different key silently invalidates every session and
  # API token). Read from the host by the unit's `docker run --env-file` as root, so the
  # 0400-root mode is fine; the container process never touches the file itself.
  secretEnvFile = "${dataDir}/secret.env";
  secretEnvScript = pkgs.writeShellScript "paperless-secret-env" ''
    set -u
    if [ ! -s ${secretEnvFile} ]; then
      umask 0177
      key=$(${pkgs.openssl}/bin/openssl rand -base64 96 | ${pkgs.gnused}/bin/sed 's/[^A-Za-z0-9_-]//g' | ${pkgs.coreutils}/bin/head -c 64)
      printf 'PAPERLESS_SECRET_KEY=%s\n' "$key" > ${secretEnvFile}
      chmod 0400 ${secretEnvFile}
    fi
  '';

  # Pinned, not nixpkgs-allocated, because the container starts ROOTLESS (`user` below) and
  # `oci-containers` resolves the uid:gid string at eval time: the host's /etc/passwd pair
  # and the ownership of every bind mount must be these numbers, everywhere, forever.
  # 952:949 is what hp's allocator first gave the paperless user (2026-10-30) - and pinning
  # is NOT retargeting: measured the same night, NixOS never usermods/groups a DIFFERENT
  # number onto an existing account (a `groupmod -g 952` even fails outright here, because
  # the `mas` group holds gid 952). So this module adopts the ids hp already has rather
  # than demanding new ones; the pair is a module-level constant, and a future host that
  # cannot create it fails loudly at tmpfiles time, not silently at container start.
  paperlessUid = 952;
  paperlessGid = 949;
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
        a policy list, not a tuning knob. Every entry must have its
        `tesseract-ocr-<lang>` pack BAKED into the image: the s6 init only installs
        missing packs via apt-get, which the rootless container cannot do.
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

            docker exec paperless python3 manage.py drf_create_token <username>

        (no `-u` needed - the container already runs as the pinned paperless uid; or in
        the UI: Administration -> Auth tokens) and store it with

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

      users.groups.paperless.gid = paperlessGid;
      users.users.paperless = {
        uid = paperlessUid;
        isSystemUser = true;
        group = "paperless";
        home = dataDir;
      };

      systemd.tmpfiles.rules = [
        # The parent stays root's 0700: it holds root's secret.env as well as the app
        # trees, which belong to the pinned uid the rootless container runs as.
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

        # No healthCheck option exists in oci-containers, and extraOptions entries are
        # rendered as individually shell-quoted argv words (verified in hp's trilium-start
        # script), so the value keeps its spaces and docker runs it as a CMD-SHELL.
        extraOptions = [
          "--network=host"
          "--health-cmd=valkey-cli -h 127.0.0.1 -p ${toString config.PORTS.paperlessBroker} ping | grep -q PONG"
        ];
      };

      virtualisation.oci-containers.containers.paperless = {
        inherit (cfg) image;
        # Keeps the unit at paperless.service, like omniroute.nix/trilium.nix.
        serviceName = "paperless";

        dependsOn = ["paperless-broker"];

        # ROOTLESS start, and that is load-bearing, not hygiene. Started as root, the s6
        # init "fixes" the image's 1000:1000 paperless to USERMAP_UID by running
        # `usermod --non-unique --uid <n> paperless` - which chowns EVERY file the image
        # owns, and the image's HOME is /usr/src/paperless, i.e. the whole Django tree
        # plus the bind-mounted data/media/consume (hp, 2026-10-30: init stalled ~5 min
        # in that recursive chown on every single start; `unhealthy` long after the
        # migrations were done). Run as a non-root uid instead and the image takes its
        # supported non-root path everywhere (its own scripts say so): init-modify-user
        # exits early, init-folders warns instead of chowning, svc-*/run exec their
        # daemon directly instead of through s6-setuidgid, and the Dockerfile pre-sets
        # /run 1777 and strips s6-overlay-suexec's setgid bit "for rootless
        # operation/compat". The host uid must therefore be PINNED and pre-own the trees
        # (tmpfiles above), since nothing inside the container can chown anything.
        user = "${toString paperlessUid}:${toString paperlessGid}";

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

        environmentFiles = [secretEnvFile];

        # Host networking like omniroute/trilium/joplin (loopback binds need no published
        # port). The image's own HEALTHCHECK curls localhost:8000 unconditionally - it does not
        # follow PAPERLESS_PORT, so with granian on 8135 it would mark a perfectly
        # serving container `unhealthy` forever. Check the real port. start-period
        # covers first-boot migrations (the sqlite DB is created by init-migrations
        # before the web server exists; measured under a minute on hp).
        extraOptions = [
          "--network=host"
          "--health-cmd=curl --fail --silent http://127.0.0.1:${toString config.PORTS.paperless}/ >/dev/null"
          "--health-interval=30s"
          "--health-start-period=3m"
        ];
      };

      # mkAfter keeps this behind the module's own pull-time pre-start; ExecStartPre runs
      # before the unit's `docker run`, so the key exists on the very first start.
      systemd.services.paperless.serviceConfig.ExecStartPre = mkAfter ["+${secretEnvScript}"];

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
