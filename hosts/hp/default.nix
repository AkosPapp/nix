{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  MODULES.services.syncthing.deviceID = "ST66PS2-5LYQY5J-LNI3FR4-3VLG7W3-F4ZHRS2-72NZMBG-QVWV2QD-6SB2DQF";
  services.tailscale = {
    extraSetFlags = ["--advertise-exit-node=true"];
    # extraSetFlags = ["--accept-dns=true" "--accept-routes=true"];
    useRoutingFeatures = "both";
  };
  networking.enableIPv6 = false;

  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;
  MODULES.security.sops.enable = true;
  # MODULES.system.printing.enable = true;
  # services.printing.openFirewall = true;
  # services.printing.listenAddresses = [
  #   "127.0.0.1:${toString config.PORTS.cups}"
  #   "${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.cups}"
  # ];
  # services.printing.allowFrom = ["all"];
  # MODULES.networking.traefik.path_routes = {
  #   "/cups" = "http://127.0.0.1:${toString config.PORTS.cups}";
  # };

  MODULES.networking.traefik.enable = true;
  MODULES.services.homepage.enable = true;
  MODULES.services.firefly-iii.enable = true;
  MODULES.services.grafana.enable = true;
  MODULES.services.loki.enable = true;
  # hp is the CPU worker as well as the gateway. It cannot run the FP8 checkpoints legion5
  # serves - vLLM's FP8 kernels require a CUDA device (Fp8Config.get_min_capability() == 75) -
  # so every entry here is legion5's model rebuilt at a size and precision a CPU can actually
  # load, filed under the same catalogue key. That sameness of key is the whole point: LiteLLM
  # groups deployments by name, so each of these ends up as a second deployment of one logical
  # model, which is what buys both the fan-out (concurrent requests split 8:1 toward the GPU)
  # and the failover (legion5 is a laptop and is usually shut; hp answers, slowly, regardless).
  MODULES.services.vllm.enable = true;
  MODULES.services.vllm.acceleration = "cpu";
  MODULES.services.vllm.cpuKvCacheSpaceGiB = 2;

  # One model resident at a time. On a GPU host `exclusive` is about vLLM's fixed VRAM
  # reservation; here it is plain arithmetic - ~8 GiB of small-text weights, ~6 GiB of
  # receipt-vision and a 2 GiB KV reservation each is 18 of this machine's 21 GiB, before
  # Immich ML, Prometheus, Loki, Grafana and Traefik get a look in. Serialising them costs a
  # model reload whenever traffic alternates between the two; not serialising them costs an OOM
  # kill of whichever process the kernel picks, which may well not be vLLM. Drop this if the
  # catalogue here ever shrinks back to a single entry.
  MODULES.services.vllm.exclusive = true;

  MODULES.services.vllm.models = {
    # unsloth's FP8 repo is a quantization of this one, so this is legion5's small-text at the
    # base precision. ~8 GiB of bf16 weights plus the 2 GiB KV reservation. `free` claims only
    # ~5 GiB available, but ~11 GiB of that is ZFS ARC, which is reclaimable down to c_min and
    # will be evicted under this allocation rather than blocking it. maxModelLen is 4096 rather
    # than the model's 256K for the same reason - vLLM reserves the KV cache for the full
    # declared context up front.
    small-text = {
      repo = "Qwen/Qwen3-4B-Instruct-2507";
      maxModelLen = 4096;
      dtype = "bfloat16";
    };

    # Deliberately not legion5's Qwen3-VL. That one is FP8, which rules it out on CPU by itself,
    # but it is also the newest VL architecture vLLM carries, and the newest multimodal model
    # class is the worst thing to hand the CPU backend - that backend gets a fraction of the
    # upstream testing the CUDA one does, and it is the recently-added architectures that fall
    # off it. Qwen2.5-VL is the previous generation of the same lineage: a separate vLLM model
    # class with a great deal more mileage behind it, ungated on Hugging Face (this host sets no
    # hfTokenFile, so a gated repo would 401), and 3B rather than 4B, which is most of what
    # makes it plausible on four Zen+ cores at all. It also stays unusually strong on dense
    # printed text, which is the entire job here - the general-purpose VLMs in this size class
    # (SmolVLM at 2B, Gemma 3 at 4B) are cheaper to run and visibly worse at reading a receipt.
    #
    # Expect tens of seconds per image, not the second or two legion5 takes. This entry earns
    # its place by existing while the laptop is shut, not by being fast.
    receipt-vision = {
      repo = "Qwen/Qwen2.5-VL-3B-Instruct";
      maxModelLen = 8192;
      dtype = "bfloat16";
      # The single biggest lever on the CPU backend. Qwen-VL's encoder is dynamic-resolution and
      # its default ceiling is ~12.8M pixels, so a phone photo of a receipt becomes thousands of
      # visual tokens - every one of them prefilled on four cores before the first output token
      # appears, and every one of them charged against maxModelLen. 1280 * 28 * 28 caps that at
      # ~1280 tokens, which is still ample to read printed text off a receipt.
      extraArgs = ["--mm-processor-kwargs" ''{"max_pixels": 1003520}''];
    };
  };

  # hp is the always-on node, so the gateway lives here rather than on the laptop, and it is
  # hp's Tailscale name that goes in a client config.
  MODULES.services.litellm.enable = true;
  # Inert while hp serves every name legion5 does: litellm.nix only builds fallbacks for models
  # no local host has, and there are none now that receipt-vision is served here too. Kept
  # because it stays the right answer the moment that changes - of the entries on this host it
  # is the cheap one, and a degraded reply from it beats a connection error.
  MODULES.services.litellm.fallbackModel = "small-text";
  MODULES.services.prometheus.enable = true;
  MODULES.services.sftpgo.enable = true;
  MODULES.services.i2pd.enable = false;
  MODULES.services.immich.machineLearning.enable = true;
  # MODULES.services.transmission.enable = true;
  # MODULES.services.searx.enable = true;
  MODULES.nix.substituters.airlab-attic.enable = true;
  MODULES.nix.substituters.airlab-attic.push.enable = true;

  networking = {
    useDHCP = lib.mkForce true;
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandlePowerKey = "ignore";
  };

  # services.cron = {
  #   enable = true;
  #   systemCronJobs = [
  #     "0 5 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g performance"
  #     "0 5 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=20000 --fast-limit=30000 --slow-limit=15000 --tctl-temp=90"

  #     "30 20 * * * root ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -g powersave -d 100 -u 100"
  #     "30 20 * * * root ${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=500 --fast-limit=1000 --slow-limit=100 --tctl-temp=30"
  #   ];
  # };

  networking = {
    networkmanager.enable = lib.mkForce true;
  };
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
  };
}
