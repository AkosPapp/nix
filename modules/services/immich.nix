{
  config,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge;

  cfg = config.MODULES.services.immich;

  # every host defined in the flake, so the machine-learning worker URLs below can be wired up
  # automatically instead of by hand (same pattern as modules/services/syncthing.nix)
  allHostNames = builtins.attrNames nixosConfigurations;
  hostConfig = host: nixosConfigurations.${host}.config;
  hostImmich = host: (hostConfig host).MODULES.services.immich;

  localMlUrl = "http://localhost:${toString config.PORTS.immichMachineLearning}";

  # other hosts in the flake that run an immich-machine-learning worker, reachable over Tailscale.
  # Immich tries `machineLearning.urls` in order and sticks with the first one that responds -
  # it's a failover chain, not a load balancer - so higher-priority hosts (e.g. ones with a GPU)
  # are sorted first to make sure they actually get used instead of just sitting as a cold spare.
  remoteAiHosts = map (h: h.host) (lib.sort (a: b:
      if a.priority != b.priority
      then a.priority > b.priority
      else a.host < b.host)
    (map
      (host: {
        inherit host;
        priority = (hostImmich host).machineLearning.priority;
      })
      (builtins.filter
        (host: host != configName && (hostImmich host).machineLearning.enable)
        allHostNames)));

  remoteAiHostUrls =
    map
    (host: "http://${(hostConfig host).MODULES.networking.tailscale.hostIP}:${toString config.PORTS.immichMachineLearning}")
    remoteAiHosts;

  # remote workers first (dedicated AI hosts), local worker last as a fallback - matches Immich's
  # own recommendation of appending rather than replacing the default local URL
  aiHostUrls = remoteAiHostUrls ++ [localMlUrl];
in {
  options.MODULES.services.immich = {
    enable = mkEnableOption "Immich photo and video backup";

    machineLearning.enable = mkEnableOption ''
      this host's immich-machine-learning worker, so it contributes AI compute (face detection,
      CLIP smart search) to the immich server. Works standalone (without MODULES.services.immich.enable)
      for hosts that should only run the worker - whichever host does have
      MODULES.services.immich.enable auto-discovers every host in the flake with this enabled and
      wires them into `settings.machineLearning.urls`, no manual URL configuration required
    '';

    machineLearning.priority = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        Where this host's worker lands in `settings.machineLearning.urls` relative to other
        remote workers - higher goes first. Immich tries the list in order and keeps using the
        first host that responds, rather than balancing across all of them, so give a host a
        higher priority (e.g. one with a GPU) to make sure it's actually the one doing the work
        instead of sitting idle behind an equally-healthy but slower host that happens to sort
        first alphabetically. Ties fall back to alphabetical order. Irrelevant to the host's own
        local worker, which is always appended last as the final fallback.
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.immich = {
        enable = true;
        host = "127.0.0.1";
        port = config.PORTS.immich;
      };

      # Point the server at every AI host discovered above, not just its own local worker.
      services.immich.settings.machineLearning.urls = aiHostUrls;

      # Quadrupled from Immich's defaults (3/5/5/5/2/2/1/5/1) now that hp and legion5 both
      # contribute worker capacity - facialRecognition and storageTemplateMigration aren't
      # in this list because Immich doesn't let their concurrency be configured at all.
      services.immich.settings.job = {
        thumbnailGeneration.concurrency = 12;
        metadataExtraction.concurrency = 20;
        library.concurrency = 20;
        sidecar.concurrency = 20;
        smartSearch.concurrency = 8;
        faceDetection.concurrency = 8;
        videoConversion.concurrency = 4;
        migration.concurrency = 20;
        ocr.concurrency = 4;
      };

      # Immich's mobile/desktop clients talk to the API at the server root, so it can't be
      # reverse-proxied under a Traefik subpath like the other services - give it its own
      # Tailscale-served HTTPS port instead, forwarding straight to the local backend.
      MODULES.networking.tailscale.serve.immich = {
        target = "http://127.0.0.1:${toString config.PORTS.immich}";
        httpsPort = config.PORTS.immich;
      };
    })

    (mkIf cfg.machineLearning.enable {
      services.immich.enable = true;
      services.immich.machine-learning.enable = true;
      services.immich.machine-learning.environment = {
        IMMICH_HOST = lib.mkForce "0.0.0.0";
        IMMICH_PORT = lib.mkForce (toString config.PORTS.immichMachineLearning);
      };

      networking.firewall.allowedTCPPorts = [config.PORTS.immichMachineLearning];

      # A machine-learning-only host has no database/redis/server of its own - strip them out so
      # immich-server doesn't spin up and crash-loop hunting for a database that isn't there.
      services.immich.database.enable = mkIf (!cfg.enable) false;
      services.immich.redis.enable = mkIf (!cfg.enable) false;
      systemd.services.immich-server.enable = mkIf (!cfg.enable) false;
    })
  ];
}
