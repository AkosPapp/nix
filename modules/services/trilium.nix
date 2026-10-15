{
  config,
  lib,
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

    etapiTokenSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "trilium/etapi_token";
      description = ''
        sops secret holding an ETAPI token for Hermes. Manual one-time step (nothing can mint one
        before a human has logged in, same shape as n8n.nix's `apiKeySecret`): open
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
  ];
}
