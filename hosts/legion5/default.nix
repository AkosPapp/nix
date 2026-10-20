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

  # opencode itself (just the litellm.hp provider, no local models) is configured once in
  # users/akos.nix, not per-host.

  MODULES.nix.substituters.airlab-attic.enable = true;
  MODULES.system.printing.enable = true;
  MODULES.hardware.nvidia.enable = true;
  MODULES.hardware.perifirals.mice.openmouse.enable = true;
  # ZED 2i capture camera: no USB runtime suspend (see modules/hardware/perifirals/zed.nix).
  MODULES.hardware.perifirals.zed.enable = true;
  USERS.akos.enable = true;
  # Paseo harness machine, declaratively - the twin of the `curl .../install/<token>/pi.sh |
  # bash` installer (leftovers from it: bash packages/paseo/machine/cleanup-home.sh). A Paseo
  # daemon runs as akos, dials out to hp's relay and registers itself on hp's cockpit
  # automatically; harnesses are opted into individually per user. akos is always on the
  # tailnet, so both harnesses use the same LiteLLM gateway as the interactive setup
  # (MODULES.services.opencode in users/akos.nix): same provider id, model and sops key, so
  # the configs the daemon writes (~/.pi/agent/models.json, ~/.config/opencode/opencode.json)
  # match what the shells already use - pi/opencode on a prompt work identically by hand.
  # If the script's user unit is still around, retire it first:
  #   systemctl --user disable --now paseo && rm ~/.config/systemd/user/paseo.service
  MODULES.services.paseo-machine = {
    enable = true;
    modelBaseUrl = "https://litellm.hp/v1";
    modelProvider = "litellm";
    modelProviderLabel = "LiteLLM (hp)";
    modelId = "futurelab/qwen3.8-flash-next";
    modelApiKeySecret = "opencode/litellm_api_key";
    # What this one model can do, restated for the harness configs (pi's contextWindow /
    # maxTokens / thinkingLevelMap, opencode's limit / variants) - same numbers and levels as
    # users/akos.nix declares for the interactive opencode entry, so a daemon prompt and a shell
    # prompt see one model. Per model on purpose: nothing here applies to a model this host does
    # not name.
    modelContextLength = 262144;
    modelOutputLength = 32768;
    modelThinkingLevels = ["low" "medium" "xhigh"];
    users.akos.harnesses = {
      pi.enable = true;
      opencode.enable = true;
    };
  };
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

  # Split DNS for robo4you.at without touching anything else: systemd-resolved (whose stub
  # resolv.conf tailscale detects and feeds natively, so its accept-dns stays on and every other
  # lookup behaves exactly as before) plus a dns-delegate sending the zone to netbird's DNS group
  # - netbird advertises the group's address as 172.18.0.1:53, but that is this host's own (down)
  # docker bridge, so the same server is reached through r4uai01's netbird IP. That peer sits
  # behind lazy connections. The delegate carries ONLY r4uai01's netbird IP: every candidate the
  # zone can fall to (the tailscale resolver's akos01 delegation, and netbird's own upstream)
  # answers happily even when its netbird path is stale - with the PUBLIC view, i.e. a NODATA
  # whose SOA carries Cloudflare's 1800s negative TTL - and a second delegate server merely let
  # that fast wrong answer race the right one; caching such an negative is exactly what produced
  # the observed "works, stops working, works again after ~half an hour" cycle. So the zone is
  # sent only to the server that knows futurelab (direct dig against it always answered, even
  # while resolved showed the poisoned negative), and Cache=no-negative stops resolved ever
  # storing negative answers at all: a transient miss is retried live instead of blinding the
  # zone until the SOA's TTL expires. Netbird deliberately keeps
  # DisableDNS (NB_DISABLE_DNS in users/akos.nix): its group advertises 172.18.0.1, which is
  # unreachable from most hosts, and its zone list predates futurelab.robo4you.at. Deliberately
  # NOT solved with networkd managing wt0: networkd wipes the address/route config netbird put on
  # the interface and leaves it admin-down (resolved ignores the DNS of a link that is not up),
  # and wait-online then times out on it.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSOverTLS = "false";
      DNSSEC = "false";
      Cache = "no-negative";
    };
    dnsDelegates.robo4you = {
      Delegate = {
        DNS = ["100.124.160.88"];
        Domains = ["robo4you.at"];
      };
    };
  };

  # r4uai01 sits behind netbird lazy connections: after an idle period the first packet to it is
  # dropped while the tunnel wakes, the delegate server times out (5s), and the lookup falls to
  # the tailscale resolver, which answers instantly with the public view (a NODATA that kills
  # internal names). Keeping the peer awake removes the failure mode entirely: one trivial query
  # every 20s ensures the delegate answers first and live.
  systemd.services.netbird-dns-keepalive = {
    description = "Keep netbird's DNS peer (r4uai01) awake for robo4you.at resolution";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.dnsutils}/bin/dig @100.124.160.88 robo4you.at SOA +short +time=1 +tries=1";
    };
  };
  systemd.timers.netbird-dns-keepalive = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5s";
      OnUnitActiveSec = "20s";
    };
  };
}
