{
  pkgs,
  config,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  # Every /var/lib/* share any other host in the flake exposes over Syncthing (e.g. Grafana's
  # dashboardsDir, Prometheus's rulesDir), mirrored here read/write so they're all browsable
  # under one directory rather than scattered across legion5's own /var/lib. Stored under
  # ~/servers instead of literally at /var/lib since none of these services actually run here.
  otherHostNames = builtins.filter (h: h != configName) (builtins.attrNames nixosConfigurations);

  varLibSharePaths = lib.unique (
    lib.flatten (map (
        host:
          map (s: s.path) (
            builtins.filter (s: lib.hasPrefix "/var/lib" s.path)
            (nixosConfigurations.${host}.config.MODULES.services.syncthing.shares)
          )
      )
      otherHostNames)
  );

  varLibShares =
    map (path: {
      inherit path;
      override_path = "/home/akos/servers${path}";
    })
    varLibSharePaths;
in {
  imports = [./hardware-configuration.nix];

  MODULES.services.immich.machineLearning.enable = true;
  # legion5 has an nvidia GPU (MODULES.hardware.nvidia.enable below) - prioritize it over hp's
  # CPU-only worker so it's actually the one doing the work instead of sitting idle behind hp,
  # which otherwise always wins by sorting first alphabetically in the failover chain.
  MODULES.services.immich.machineLearning.priority = 10;
  # Inference runs on the 4060: MODULES.services.immich.machineLearning.acceleration defaults to
  # "cuda" here off MODULES.hardware.accelerator. The earlier from-scratch magma/hwloc build that
  # kept this on the CPU is gone - cache.nixos-cuda.org (MODULES.nix.substituters.cuda, enabled in
  # profiles/global.nix) has the cudaSupport closure prebuilt, so the switch is a download.
  # Gunicorn worker processes for immich-machine-learning - bumped from the default of 1 to let
  # it handle more than one request at a time. Each worker loads its own copy of the models into
  # VRAM now that they run on the card, on top of whatever Ollama is holding - drop back to 1 if
  # the worker starts failing allocations.
  services.immich.machine-learning.environment.MACHINE_LEARNING_WORKERS = lib.mkForce "2";
  MODULES.security.sops.enable = true;

  # The GPU worker: an RTX 4060 laptop card, 8 GiB, which also drives the desktop session. Ollama
  # sizes memory to the loaded model plus its configured context and spills whatever does not fit
  # onto the CPU, so a model larger than the card answers slowly rather than refusing to start.
  # The CUDA build comes prebuilt from the cache.nixos-cuda.org substituter enabled in
  # profiles/global.nix.
  #
  # Two coding models, split by how much the task is worth waiting for:
  # - coder: Qwen2.5-Coder-7B, 4.7 GB, dense. The light one - it is the only entry whose weights
  #   nearly fit the ~3.6 GiB the card offers after gpuOverheadMiB, so it is by far the fastest.
  #   Its q8_0 cache costs ~30 KiB per token (28 layers x 4 KV heads x 128), so 64K x 2 parallel
  #   slots is ~3.8 GiB on top of the weights: most of that lands in system RAM. Halving
  #   contextLength is the lever if it feels slow.
  # - gpt-oss: OpenAI's 20B, 13.8 GB, mixture-of-experts with ~3.6B parameters active per token.
  #   For the complex jobs: far more capable than anything dense that fits here, and the small
  #   active share keeps it usable even though most of it sits in RAM. It reasons before
  #   answering, so the first token takes noticeably longer.
  # - heretic: the Q6_K of p-e-w's decensored Qwen3-8B, 6.73 GB. 16384 context.
  # - small-text: Qwen3-4B-2507 Q4_K_M. 8192, the cheap one, and what opencode uses for its side
  #   jobs. receipt-vision is hp-only again - this host no longer carries a vision model.
  MODULES.services.ollama.enable = true;
  MODULES.services.ollama.weight = 8;
  # Keep ~1.5 GiB of the card out of Ollama's layer placement. It sizes a model to the memory free
  # at load time, but the desktop's share swings between ~0.9 and ~2.7 GiB and a vision model's
  # image encoder allocates on top at request time - receipt-vision-7b died with "cudaMalloc
  # failed: out of memory" mid-request. With the reserve, the layers that would not have fit run
  # from system RAM on the CPU instead: slower for the large models, but they answer.
  MODULES.services.ollama.gpuOverheadMiB = 1536;
  MODULES.services.ollama.models = {
    coder = {
      source = "qwen2.5-coder:7b";
      contextLength = 65536;
    };
    "qwen3.5" = {
      source = "hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_1";
      contextLength = 65536;
    };
    gpt-oss = {
      source = "gpt-oss:20b";
      contextLength = 65536;
    };
    heretic = {
      # Ollama's hf.co/ source only pulls GGUF repositories. p-e-w publishes the heretic models as
      # safetensors (p-e-w/Qwen3-8B-heretic is a single model.safetensors), so the pull failed;
      # this is the GGUF build of that same model. Q6_K is 6.73 GB - closer to the original than
      # Q4_K_M (5.03 GB), but already more than the ~5.16 GiB the desktop leaves free before any
      # cache, so Ollama runs a sizeable share of its layers on the CPU and it is the slowest
      # model here. Q4_K_M is the one to go back to if that becomes the bottleneck.
      source = "hf.co/mradermacher/Qwen3-8B-heretic-GGUF:Q6_K";
      # source = "p-e-w/gemma-3-12b-it-heretic"; # also safetensors-only - needs a GGUF build too
      contextLength = 16384;
    };
    small-text = {
      source = "qwen3:4b-instruct-2507-q4_K_M";
      contextLength = 16384;
    };
  };

  # opencode against this Ollama. receipt-vision is left out: Ollama serves qwen2.5vl without
  # tool support, and opencode does everything through tool calls. coder and small-text are
  # listed with tools in the Ollama library; heretic is a Hugging Face GGUF whose tool support
  # depends on the chat template Ollama derives, so it may refuse tool calls. coder by default,
  # small-text for opencode's side jobs (titles) so they don't swap the 32K coder out.
  MODULES.services.ollama.opencode = {
    enable = true;
    models = ["coder" "gpt-oss" "heretic" "small-text"];
    defaultModel = "coder";
    smallModel = "small-text";
  };

  MODULES.nix.substituters.airlab-attic.enable = true;
  MODULES.system.printing.enable = true;
  MODULES.hardware.nvidia.enable = true;
  MODULES.hardware.perifirals.mice.openmouse.enable = true;
  USERS.akos.enable = true;
  MODULES.networking.tailscale.hostIP = "100.126.232.60";
  MODULES.services.syncthing.deviceID = "U6G2UZ4-RX5WVKR-5MAIXOA-4GX6ZL6-PGTAPWD-KXLK3V4-N4EPLT3-GWR7MQ7";
  # Shares live under akos's home directory, which the default "syncthing" system user can't
  # read; run as akos instead (see MODULES.services.syncthing.user's description for why
  # running as root doesn't work for this).
  MODULES.services.syncthing.user = "akos";
  MODULES.services.syncthing.group = "users";
  MODULES.services.syncthing.shares =
    [
      {
        path = "/home/akos/Pictures/dcim";
        copyOwnershipFromParent = true;
        extra_devices = ["phone"];
      }
      {
        # Everything under ~/Pictures (including dcim, see above) mirrored to hp - moving a phone
        # photo out of dcim into any other spot under here is how it stops being tied to the phone's
        # camera roll: from then on it's just a plain legion5<->hp synced file, immune to whatever
        # happens on the phone. dcim itself is excluded here since it's already its own folder above
        # (synced with the phone too) - without excluding it, this folder and the dcim one above
        # would both try to manage the same files, which Syncthing does not handle well.
        path = "/home/akos/Pictures";
        copyOwnershipFromParent = true;
        ignorePatterns = ["/dcim"];
      }
      {
        path = "/home/akos/notes";
        copyOwnershipFromParent = true;
        extra_devices = ["phone"];
      }
    ]
    ++ varLibShares;
  PROFILES.zroot.enable = true;
  services.displayManager.ly.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    lm_sensors
    psutils
    runc
    cudatoolkit
  ];

  boot.extraModulePackages = with config.boot.kernelPackages; [
    lenovo-legion-module
  ];

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "sleep";
    HandlePowerKey = "sleep";
  };

  services.znapzend = {
    enable = true;
    pure = true;
    autoCreation = true;
    logLevel = "debug";
    logTo = "/var/log/znapzend.log";
    features = {
      # compressed = true;
      lowmemRecurse = true;
      # skipIntermediates = true;
    };
    zetup."zroot/persist/legion5" = {
      recursive = true;
      # plan = "1h=>1min,1d=>1h,1w=>1d,5m=>1w";
      plan = "1h=>1min,1d=>1h,1w=>1d";
      enable = true;
      destinations = {
        hp = {
          host = "root@hp";
          dataset = "zroot/persist/legion5";
          plan = "1h=>1min,1d=>1h,1w=>1d";
        };
      };
    };
  };
  # systemd.services.znapzend.serviceConfig.ExecStart = let
  #   args = lib.concatStringsSep " " [
  #     "--logto=${config.services.znapzend.logTo}"
  #     "--loglevel=${config.services.znapzend.logLevel}"
  #     "--autoCreation"
  #     "--debug"
  #   ];
  # in
  #   lib.mkForce "${pkgs.znapzend}/bin/znapzend ${args}";

  services.power-profiles-daemon.enable = true;

  # Set rtprio limits for real-time priority
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "-";
      item = "rtprio";
      value = "98";
    }
  ];

  # Increase network buffer sizes
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 20971520;
    "net.core.rmem_default" = 20971520;
    "net.core.wmem_max" = 20971520;
    "net.core.wmem_default" = 20971520;
  };
}
