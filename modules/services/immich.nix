{
  config,
  lib,
  pkgs-unstable,
  inputs,
  system,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge;

  cfg = config.MODULES.services.immich;

  # A second unstable nixpkgs with cudaSupport on, which is the only switch the machine-learning
  # worker has: immich-machine-learning takes no cuda argument of its own, it inherits whatever
  # execution providers python onnxruntime was built with, and onnxruntime follows the global
  # flag. Kept as its own pkgs instance so the CUDA variants stay inside immich instead of
  # leaking into everything else this flake pulls from unstable (tailscale, vaultwarden, niri).
  # The config attrs are flake.nix's plain unstable import plus cudaSupport and cudaCapabilities
  # is deliberately left at the nixpkgs default - that combination is what
  # cache.nixos-cuda.org (MODULES.nix.substituters.cuda) builds, so the whole closure
  # substitutes. Narrowing capabilities to this card's 8.9 would be a cache miss and a
  # from-scratch onnxruntime/opencv build.
  pkgs-unstable-cuda = import inputs.nixpkgs-unstable {
    inherit system;
    config = {
      allowUnfree = true;
      allowBroken = true;
      cudaSupport = true;
    };
  };

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

    machineLearning.acceleration = lib.mkOption {
      type = lib.types.enum ["cpu" "cuda"];
      default =
        if config.MODULES.hardware.accelerator == "cuda"
        then "cuda"
        else "cpu";
      defaultText = lib.literalMD ''"cuda" when `MODULES.hardware.accelerator` is "cuda", otherwise "cpu"'';
      description = ''
        Which backend the worker runs face detection and CLIP on. "cuda" swaps the whole immich
        package for one built out of a cudaSupport nixpkgs and opens the card's device nodes to
        the unit; "cpu" is the plain build. ROCm is not an option - immich's worker only ships
        CPU and CUDA execution providers. Defaults to CUDA on a host with an NVIDIA card: a
        ~4.6 GiB first-time download from cache.nixos-cuda.org for the worker, plus ~1.5 GiB
        more on a host that also runs the immich server off the same package.
      '';
    };
  };

  config = mkMerge [
    # nixpkgs 26.05 is stuck on Immich 2.7.5, which upstream has stopped updating - 3.x only
    # reaches stable with 26.11 - so take the package from unstable instead. That picks up the
    # fix for CVE-2026-59258 (an editor on a shared album could demote the owner and take it
    # over, fixed in 3.0.3); CVE-2026-82272 (locked assets still readable through albums and
    # shared links) has no released fix yet - it's patched in git but 3.1.0 is the newest tag.
    # Drop this override once the flake's stable nixpkgs is 26.11 or later.
    #
    # One option covers both the server and the machine-learning worker (the latter is a
    # passthru of the same derivation), and Immich requires the two to be on the same version,
    # so every host in the flake has to be deployed together when this moves.
    (mkIf (cfg.enable || cfg.machineLearning.enable) {
      services.immich.package =
        if cfg.machineLearning.acceleration == "cuda"
        then pkgs-unstable-cuda.immich
        else pkgs-unstable.immich;
    })

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

      # The upstream module's default of accelerationDevices = [] turns on PrivateDevices, which
      # hides /dev/nvidia* from the unit - onnxruntime then finds no CUDA device and silently
      # falls back to the CPU provider. List the card's nodes instead of using `null` (all
      # devices) so the rest of the hardening stays.
      services.immich.accelerationDevices = mkIf (cfg.machineLearning.acceleration == "cuda") [
        "/dev/nvidiactl"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
        "/dev/nvidia0"
        "/dev/nvidia-modeset"
      ];

      networking.firewall.allowedTCPPorts = [config.PORTS.immichMachineLearning];

      # A machine-learning-only host has no database/redis/server of its own - strip them out so
      # immich-server doesn't spin up and crash-loop hunting for a database that isn't there.
      services.immich.database.enable = mkIf (!cfg.enable) false;
      services.immich.redis.enable = mkIf (!cfg.enable) false;
      systemd.services.immich-server.enable = mkIf (!cfg.enable) false;
    })
  ];
}
