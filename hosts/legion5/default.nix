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
  # CUDA support pulled in a from-scratch build of magma and hwloc (no cache hit for this
  # capability/nixpkgs combination) - not worth the build time, so this stays on CPU inference.
  # Gunicorn worker processes for immich-machine-learning - bumped from the default of 1 to let
  # it handle more than one request at a time.
  services.immich.machine-learning.environment.MACHINE_LEARNING_WORKERS = lib.mkForce "2";
  MODULES.security.sops.enable = true;

  # The GPU worker. Both entries are FP8 checkpoints, and vLLM's FP8 path requires a CUDA
  # device of compute capability 7.5 or better (Fp8Config.get_min_capability() == 75), so these
  # exact repos are legion5-only. hp serves the same small-text model from the base bf16 repo
  # instead, which is what keeps the name answerable while this laptop is shut.
  #
  # The card is an RTX 4060 Max-Q, 8 GiB, Ada (sm_89) - native FP8, so these load without the
  # Marlin fallback. Two ~4B FP8 models is about 4.3 GiB of weights each, which is why
  # `exclusive` is on: they cannot both be resident, and without it the second one to be woken
  # dies with a CUDA OOM instead of evicting the first.
  #
  # maxModelLen is capped far below what these models allow (both go to 256K) because vLLM
  # preallocates the KV cache for it up front: at 0.85 of 8 GiB, minus weights, there is roughly
  # 2.5 GiB of cache to spend, and 8192 tokens leaves margin. Raise it if the card turns out to
  # have more headroom than that estimate.
  #
  # gpuMemoryUtilization is below vLLM's 0.9 default because this GPU also drives a desktop
  # session, and 0.9 of 8 GiB leaves nothing for the display server.
  MODULES.services.vllm.enable = false;
  MODULES.services.vllm.acceleration = "cuda";
  MODULES.services.vllm.exclusive = true;
  # Share of the traffic for small-text, which hp also serves. Eight to hp's one is a guess at
  # the ratio between FP8 on an Ada card and bfloat16 on four Zen+ cores, not a measurement, but
  # it is on the right side of the truth: an even split would put half the concurrent requests
  # on the slow machine and let them set the latency anyone actually notices.
  MODULES.services.vllm.weight = 8;
  MODULES.services.vllm.models = {
    # Names are the client-facing aliases, not the repo ids: these are what LiteLLM advertises
    # as model_name and what goes in an OpenAI request's "model" field.
    receipt-vision = {
      repo = "Qwen/Qwen3-VL-4B-Instruct-FP8";
      maxModelLen = 8192;
      gpuMemoryUtilization = 0.85;
    };
    small-text = {
      repo = "unsloth/Qwen3-4B-Instruct-2507-FP8";
      maxModelLen = 8192;
      gpuMemoryUtilization = 0.85;
    };
  };

  MODULES.nix.substituters.airlab-attic.enable = true;
  MODULES.system.printing.enable = true;
  MODULES.hardware.nvidia.enable = true;
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
