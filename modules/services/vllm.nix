{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.vllm;

  accelerationBackends = ["cpu" "cuda" "rocm"];

  # Set by MODULES.hardware.nvidia (e.g. "--device=nvidia.com/gpu=all") on hosts whose container
  # runtime can hand the card to a container. Its presence is what makes CUDA the default
  # backend, and it is passed straight to `docker run` so the container actually sees the GPU -
  # Docker 25+ resolves the nvidia.com/gpu CDI name from the spec nvidia-container-toolkit
  # generates.
  gpuFlag = config.environment.variables.GPU_FLAG or null;

  # vLLM runs from upstream's own images rather than a nixpkgs build. The nixpkgs route meant
  # compiling torch and vLLM from source for anything but CPU (cache.nixos.org carries no
  # cudaSupport/rocmSupport builds), patching vLLM's platform probe for the CPU build, and trailing
  # upstream by several releases; the images are what upstream tests and ship.
  #
  # Pinned to one vLLM release across all three backends, so hosts on different hardware still
  # serve the same engine version behind LiteLLM.
  defaultImages = {
    cuda = "vllm/vllm-openai:v0.27.0";
    cpu = "public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.27.0";
    rocm = "rocm/vllm:rocm10.0.0_ubuntu24.04_py3.14_pytorch_2.12.0_vllm_0.27.0";
  };

  isGpu = cfg.acceleration != "cpu";

  # Whether instances are started on demand and torn down when idle, rather than held resident
  # from boot. Drives the whole socket/proxy arrangement further down.
  lazy = cfg.idleTimeout != null;

  stateDir = "/var/lib/vllm";
  hfCache = "${stateDir}/huggingface/hub";

  # Every model this host is asked to serve, in a stable order, so the port each one lands on is
  # a function of the catalogue rather than of attrset iteration order. Sorting by name means
  # adding a model renumbers the ones after it alphabetically - acceptable because nothing
  # outside this flake hardcodes these ports (LiteLLM reads them back out of `instances`), and
  # the alternative, a hand-assigned port per model, is exactly the bookkeeping PORTS exists to
  # take over.
  servedNames = lib.sort (a: b: a < b) cfg.serve;

  instances = lib.listToAttrs (lib.imap0 (i: name:
    lib.nameValuePair name {
      inherit name;
      # The port clients reach, held open by a .socket unit whether or not the server behind it
      # is running, and the private one the server itself binds. They have to be separate: the
      # whole point is that something is listening on the front port while vLLM is stopped.
      port = cfg.basePort + i;
      backendPort = cfg.basePort + cfg.backendPortOffset + i;
      model = cfg.models.${name};
    })
  servedNames);

  # Models pulled onto this host's disk, which is not the same set as the models it serves:
  # `prefetch = "all"` warms the whole catalogue so that pointing `serve` at a different entry
  # is a restart rather than a multi-gigabyte download.
  prefetchNames =
    {
      all = lib.attrNames cfg.models;
      served = servedNames;
      none = [];
    }
    .${
      cfg.prefetch
    };

  # huggingface_hub's CLI was renamed (`huggingface-cli` -> `hf`) at 1.0 and the flag spellings
  # moved with it; snapshot_download is the same call underneath and has been stable across
  # both, so drive the library directly rather than betting on which CLI this nixpkgs ships.
  fetchPython = pkgs.python3.withPackages (ps: [ps.huggingface-hub]);

  fetchPy = pkgs.writeText "vllm-fetch.py" ''
    import os
    import sys

    from huggingface_hub import snapshot_download

    repo, revision = sys.argv[1], sys.argv[2]
    snapshot_download(
        repo,
        revision=revision,
        cache_dir=os.environ["HF_HUB_CACHE"],
        token=os.environ.get("HF_TOKEN") or None,
        max_workers=4,
    )
  '';

  # A token, when configured, arrives as a systemd credential rather than in the environment or
  # the store.
  loadTokenSnippet = ''
    if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "''${CREDENTIALS_DIRECTORY}/hf-token" ]; then
      HF_TOKEN="$(cat "''${CREDENTIALS_DIRECTORY}/hf-token")"
      export HF_TOKEN
      # huggingface_hub reads HF_TOKEN; some vLLM code paths still look at the older spelling.
      HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
      export HUGGING_FACE_HUB_TOKEN
    fi
  '';

  fetchScript = pkgs.writeShellScript "vllm-fetch-models" ''
    set -euo pipefail
    ${loadTokenSnippet}
    ${lib.concatMapStringsSep "\n" (name: let
        m = cfg.models.${name};
      in ''
        echo "vllm-fetch: ${name} -> ${m.repo}@${m.revision}"
        ${fetchPython}/bin/python ${fetchPy} ${lib.escapeShellArg m.repo} ${lib.escapeShellArg m.revision}
      '')
      prefetchNames}
  '';

  # `docker run` has no way to read a systemd credential, so the token is turned into an
  # --env-file in the unit's runtime directory just before the container starts. /run is tmpfs
  # and the directory is removed with the unit, so the token still never touches disk or the store.
  tokenEnvFile = name: "/run/vllm-${name}/hf-token.env";

  writeTokenEnvScript = name:
    pkgs.writeShellScript "vllm-${name}-token-env" ''
      set -euo pipefail
      ${loadTokenSnippet}
      umask 0077
      printf 'HF_TOKEN=%s\nHUGGING_FACE_HUB_TOKEN=%s\n' "$HF_TOKEN" "$HF_TOKEN" > ${tokenEnvFile name}
    '';

  # Flags common to every instance. `--download-dir` is deliberately absent: it makes vLLM write
  # a flat per-model directory of its own instead of using the shared HF cache the prefetch unit
  # populates, which would fetch every model a second time.
  serveArgs = instance: let
    m = instance.model;
  in
    [
      "serve"
      m.repo
      # The container shares the host's network namespace (see extraOptions below), so this is
      # the host's own address. In lazy mode the server only takes the private backend port behind
      # the proxy, which stays on loopback; with no proxy it owns the public port itself, and that
      # one has to answer other hosts over Tailscale just like the socket would.
      "--host"
      (
        if lazy
        then "127.0.0.1"
        else "0.0.0.0"
      )
      "--port"
      # In lazy mode the public port belongs to the .socket unit and the server sits behind the
      # proxy on its private one. With idleTimeout null there is no socket and no proxy, so the
      # server has to take the public port itself - otherwise it would listen on a port nothing
      # in the flake, LiteLLM included, ever connects to.
      (toString (
        if lazy
        then instance.backendPort
        else instance.port
      ))
      "--served-model-name"
      m.servedName
      "--revision"
      m.revision
    ]
    ++ lib.optionals (m.maxModelLen != null) ["--max-model-len" (toString m.maxModelLen)]
    ++ lib.optionals (m.quantization != null) ["--quantization" m.quantization]
    ++ lib.optionals (m.dtype != null) ["--dtype" m.dtype]
    ++ lib.optionals (m.gpuMemoryUtilization != null && isGpu) [
      "--gpu-memory-utilization"
      (toString m.gpuMemoryUtilization)
    ]
    ++ m.extraArgs
    ++ cfg.extraArgs;

  modelSubmodule = {name, ...}: {
    options = {
      repo = mkOption {
        type = types.str;
        example = "Qwen/Qwen3-4B-Instruct-2507";
        description = ''
          Hugging Face repository id, as it appears in the model's URL. vLLM resolves this
          through huggingface_hub at startup and downloads it if the cache is cold, so nothing
          has to be staged into the Nix store - the weights are far too large for it anyway.
          Gated repos (Meta's Llama, most of Mistral's) additionally need `hfTokenFile`.
        '';
      };

      servedName = mkOption {
        type = types.str;
        default = name;
        description = ''
          The name this model answers to over the OpenAI API - what a client puts in the "model"
          field and what appears in /v1/models. Defaults to the attribute name, which is also
          what LiteLLM advertises, so the same short handle works end to end instead of the repo
          id leaking out to clients.
        '';
      };

      revision = mkOption {
        type = types.str;
        default = "main";
        description = ''
          Git revision of the repo to pull - a branch, tag or commit sha. Left at "main", which
          means the weights are whatever upstream last pushed: this is the one part of this
          config that is not reproducible, and pinning a commit sha here is what fixes it.
        '';
      };

      maxModelLen = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 8192;
        description = ''
          Context window to serve, in tokens. Null means the model's own maximum, which is
          usually the reason a server refuses to start: vLLM preallocates a KV cache big enough
          for `maxModelLen` x `--max-num-seqs` and aborts when that doesn't fit. Lowering this
          is the first lever to pull when a model won't load.
        '';
      };

      quantization = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "awq_marlin";
        description = ''
          Quantization kernel to load the weights with ("awq", "awq_marlin", "gptq", "fp8", ...).
          Null lets vLLM read it from the repo's own config, which is right for any repo already
          published quantized; set it only to override that choice.
        '';
      };

      dtype = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "bfloat16";
        description = ''
          Weight and activation dtype. Null means "auto". Worth setting to "bfloat16" on the CPU
          backend, where "auto" resolves to float32 for many repos and doubles both the memory
          footprint and the time per token.
        '';
      };

      gpuMemoryUtilization = mkOption {
        type = types.nullOr types.float;
        default = null;
        example = 0.85;
        description = ''
          Fraction of total VRAM this instance may claim, weights and KV cache together. Ignored
          on the CPU backend. vLLM's own default is 0.9, which assumes it is the only thing on
          the card - lower it when a desktop session or a second instance shares the GPU, since
          vLLM reserves this up front rather than growing into it.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["--enable-auto-tool-choice" "--tool-call-parser" "hermes"];
        description = "Extra `vllm serve` flags for this model only.";
      };
    };
  };
in {
  options.MODULES.services.vllm = {
    enable = mkEnableOption "vLLM OpenAI-compatible inference server";

    acceleration = mkOption {
      type = types.enum accelerationBackends;
      default = config.MODULES.hardware.accelerator;
      defaultText = lib.literalExpression "config.MODULES.hardware.accelerator";
      description = ''
        Which hardware backend to run: "cpu", "cuda" (NVIDIA) or "rocm" (AMD). Selects the
        default `image` and which devices the container is given. Follows GPU_FLAG by default,
        since that variable is what says this host can pass a GPU into a container at all.

        "rocm" is only meaningful for GPUs ROCm actually supports (gfx900/906/908/90a/942/950 and
        RDNA3+); Vega-class integrated graphics are not among them, see `rocmGfxOverride`.
      '';
    };

    image = mkOption {
      type = types.str;
      default = defaultImages.${cfg.acceleration};
      defaultText = lib.literalExpression (builtins.toJSON defaultImages + ".\${acceleration}");
      description = ''
        Container image the servers run. Defaults to upstream's release image for the chosen
        backend, pinned to one vLLM version. Docker pulls it on the first start and never again
        for the same tag, so bumping the tag here is how an upgrade happens.
      '';
    };

    rocmGfxOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "9.0.0";
      description = ''
        Value for HSA_OVERRIDE_GFX_VERSION, which makes ROCm treat the installed GPU as a
        different, supported architecture. This is the usual workaround for cards that are close
        relatives of a supported one - a Vega 8 iGPU is gfx902 and ROCm only ships gfx900, so
        "9.0.0" is what gets it to enumerate at all.

        It makes ROCm load; it does not make vLLM work. vLLM's ROCm kernels target CDNA
        (gfx908/90a/942) and RDNA3, and an iGPU additionally has only the sliver of VRAM the
        firmware carved out, which a KV cache does not fit into. Treat this as worth one
        experiment, not as a supported configuration.
      '';
    };

    models = mkOption {
      type = types.attrsOf (types.submodule modelSubmodule);
      default = {};
      example = lib.literalExpression ''
        {
          qwen3-4b.repo = "Qwen/Qwen3-4B-Instruct-2507";
          qwen25-coder-7b = {
            repo = "Qwen/Qwen2.5-Coder-7B-Instruct-AWQ";
            maxModelLen = 8192;
          };
        }
      '';
      description = ''
        The catalogue of models this host knows about, keyed by the short handle clients use.
        This is the single list the rest of the stack is derived from: `serve` picks which
        entries get a vLLM process, `prefetch` decides which get downloaded, and LiteLLM reads
        the catalogue of every host in the flake to build its routing table.

        Adding a model here and rebuilding is the whole workflow - there is no runtime model
        registry. LiteLLM can do database-backed model management, but that needs
        `litellm-proxy-extras` and a working Prisma, neither of which nixpkgs currently provides
        (see the note in litellm.nix), so a declarative list is the honest option here.
      '';
    };

    serve = mkOption {
      type = types.listOf types.str;
      default = lib.attrNames cfg.models;
      defaultText = lib.literalExpression "every model in `models`";
      description = ''
        Which catalogue entries this host actually runs a vLLM container for. Defaults to all of
        them, which is right for a GPU host with a small catalogue and wrong as soon as the
        models stop fitting side by side: each instance is a separate container that loads its
        own weights and holds its own KV cache for as long as it runs, so N models cost N times
        the memory - this is not a swap-on-demand pool the way ollama was.
      '';
    };

    prefetch = mkOption {
      type = types.enum ["all" "served" "none"];
      default = "all";
      description = ''
        Which catalogue models `vllm-fetch-models.service` downloads before the servers start.
        "all" warms the entire catalogue, so moving `serve` to a different entry is a restart
        instead of a first-request download of several gigabytes; "served" fetches only what
        this host runs, which is the one to pick when disk is tighter than patience; "none"
        leaves every download to vLLM itself on first start.
      '';
    };

    cpuKvCacheSpaceGiB = mkOption {
      type = types.int;
      default = 4;
      description = ''
        VLLM_CPU_KVCACHE_SPACE: how much ordinary RAM, in GiB, each CPU-backend instance
        reserves for its KV cache. Only used when `acceleration = "cpu"`, where there is no VRAM
        budget to derive one from. It is reserved up front and it is per instance, so the figure
        to keep in mind is this times the number of entries in `serve`.
      '';
    };

    basePort = mkOption {
      type = types.int;
      default = 8100;
      description = ''
        First loopback port handed to a vLLM instance; the rest follow consecutively in the
        alphabetical order of `serve`. Not itself an entry in PORTS because the derived
        per-instance ports are registered there instead, which is what puts them under the
        flake-wide duplicate-port assertion. 8100 rather than 8000 because 8000-8099 is
        already dense with this flake's other services.
      '';
    };

    backendPortOffset = mkOption {
      type = types.int;
      default = 50;
      description = ''
        Distance from an instance's public port to the private one the vLLM process itself
        binds. Two ports per instance is a consequence of on-demand loading: the public port
        belongs to a systemd .socket that stays listening while the server is stopped, and the
        proxy behind it connects onwards to this one. Only needs changing if a catalogue ever
        grows past the gap and the two ranges would overlap - which the PORTS duplicate
        assertion turns into a build error rather than a silent collision.
      '';
    };

    idleTimeout = mkOption {
      type = types.nullOr types.int;
      default = 30;
      example = 600;
      description = ''
        Seconds of no open connection after which an instance is torn down and its weights
        dropped out of memory, with the next request starting it again. Null keeps every
        instance resident from boot, the way an ordinary always-on daemon behaves.

        This is what makes a catalogue larger than the machine's memory workable: idle models
        cost nothing but disk. The price is paid on the first request after an idle period, and
        it is not small - vLLM has to load the weights and, on a GPU, capture CUDA graphs, which
        runs from tens of seconds to several minutes depending on the model and the backend. At
        the default of 30s a bursty conversation pays that repeatedly; raise it well above the
        gap between requests if the reloads become the dominant cost.
      '';
    };

    weight = mkOption {
      type = types.int;
      default = 1;
      example = 8;
      description = ''
        This host's share of the traffic for any catalogue entry it serves that another host
        also serves. LiteLLM treats same-named deployments on different hosts as interchangeable
        replicas and picks between them at random, weighted by this number, so concurrent
        requests for one model genuinely run on several machines at once.

        The default of 1 spreads work evenly, which is only right when the hosts are comparable.
        They usually are not: a GPU host is an order of magnitude faster than a CPU one, and an
        even split there means half the requests land on the slow machine and dominate the
        latency anyone actually observes. Weight the fast host accordingly.

        Only read under LiteLLM's "simple-shuffle" routing strategy, which is what
        MODULES.services.litellm.routingStrategy defaults to for exactly this reason - the
        load-aware strategies ignore the key entirely rather than warning about it.
      '';
    };

    exclusive = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow only one of this host's instances to be loaded at a time, stopping whichever was
        resident when a different model is asked for. The point is VRAM: vLLM reserves its whole
        `gpuMemoryUtilization` share up front, so on a single card two instances sized to be
        useful individually cannot both be resident, and the second one to start dies with a
        CUDA OOM rather than politely queueing. Serialising them turns that into a slower
        answer instead of a failed one - the ollama behaviour of one model in memory at a time.

        Implemented as systemd `Conflicts` between the per-instance activation proxies, so the
        eviction cascades: dropping the proxy leaves its server unneeded, and StopWhenUnneeded
        unloads it. A request in flight against the evicted model is cut off, which is the
        honest cost of sharing one GPU between two models.

        Leave off where the instances genuinely fit side by side, or on a CPU host, where the
        constraint is total RAM rather than a fixed per-process reservation.
      '';
    };

    hfTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/huggingface/token";
      description = ''
        File holding a Hugging Face access token, passed to the prefetch job and the servers as
        a systemd credential and exported as HF_TOKEN. Needed only for gated repos - Meta's
        Llama and most of Mistral's are gated behind an accepted licence, and without a token
        they fail with a 401 that reads as though the model does not exist. A path, not the
        token itself, so it stays out of the world-readable Nix store.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra `vllm serve` flags applied to every instance on this host.";
    };

    instances = mkOption {
      type = types.attrsOf (types.attrsOf types.unspecified);
      internal = true;
      default = {};
      description = ''
        Resolved name -> {name, port, model} map for the servers this host runs. Internal: it
        exists so litellm.nix can read the ports straight off every host in the flake instead of
        recomputing the allocation and drifting out of sync with it.
      '';
    };
  };

  config = mkIf cfg.enable {
    MODULES.services.vllm.instances = instances;

    assertions = [
      {
        assertion = lib.all (n: cfg.models ? ${n}) cfg.serve;
        message = let
          missing = lib.filter (n: !(cfg.models ? ${n})) cfg.serve;
        in "MODULES.services.vllm.serve names models that are not in the catalogue: ${lib.concatStringsSep ", " missing}";
      }
      {
        assertion = cfg.acceleration != "cuda" || gpuFlag != null;
        message = ''
          MODULES.services.vllm.acceleration = "cuda" but environment.variables.GPU_FLAG is not
          set: the container would start without the GPU and vLLM would die with "Failed to
          infer device type". Enable MODULES.hardware.nvidia, which sets it.
        '';
      }
    ];

    # Registering the derived ports here rather than hardcoding them in ports.nix is what puts
    # them under the flake-wide uniqueness assertion: a catalogue that grows past the next
    # service's port becomes a build error instead of two daemons fighting over one socket.
    # Both halves of each instance are registered, so the front and backend ranges colliding is
    # caught here too.
    PORTS =
      lib.mapAttrs' (name: i: lib.nameValuePair "vllm-${name}" i.port) instances
      // lib.optionalAttrs lazy (
        lib.mapAttrs' (name: i: lib.nameValuePair "vllm-${name}-backend" i.backendPort) instances
      );

    # The public ports are what LiteLLM on other hosts connects to over Tailscale. Opened on the
    # tailnet interface only: vLLM has no authentication of its own, so the LAN must not reach it.
    # Backend ports stay closed - they are loopback-only and only the local proxy talks to them.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = lib.mapAttrsToList (_: i: i.port) instances;

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    # One container per instance. `serviceName` keeps the generated unit at vllm-<n>.service
    # rather than docker-vllm-<n>.service, which is the name the socket/proxy wiring below and
    # the systemd overrides further down all refer to.
    #
    # The containers run as root, as the images expect, and the HF cache under /var/lib/vllm is
    # root-owned to match - including the prefetch job's writes, since huggingface_hub takes
    # lock files in the cache and a second owner would leave one side unable to write.
    virtualisation.oci-containers.containers = lib.mapAttrs' (name: instance:
      lib.nameValuePair "vllm-${name}" {
        inherit (cfg) image;
        serviceName = "vllm-${name}";
        # In lazy mode nothing wants this at boot - the proxy pulls it in on the first request
        # and StopWhenUnneeded drops it again when the proxy exits.
        autoStart = !lazy;
        entrypoint = "vllm";
        cmd = serveArgs instance;

        # Same path inside as outside, so the cache the host-side prefetch job fills is exactly
        # the one vLLM reads and the environment below needs no translation.
        volumes = ["${stateDir}:${stateDir}"];
        environmentFiles = lib.optional (cfg.hfTokenFile != null) (tokenEnvFile name);

        environment =
          {
            HF_HOME = "${stateDir}/huggingface";
            HF_HUB_CACHE = hfCache;
            # vLLM phones home with anonymous usage stats unless told not to.
            VLLM_NO_USAGE_STATS = "1";
            DO_NOT_TRACK = "1";
            # Compilation artefacts and the torch inductor cache land here instead of inside the
            # container's own filesystem, which is discarded on every stop. Keeping them on the
            # host matters more in lazy mode than it would otherwise: this cache is most of what
            # stops every reload from repeating the same compilation work.
            VLLM_CACHE_ROOT = "${stateDir}/cache";
            TRITON_CACHE_DIR = "${stateDir}/cache/triton";
            XDG_CACHE_HOME = "${stateDir}/cache";
            OUTLINES_CACHE_DIR = "${stateDir}/cache/outlines";
          }
          // lib.optionalAttrs (cfg.acceleration == "cpu") {
            VLLM_CPU_KVCACHE_SPACE = toString cfg.cpuKvCacheSpaceGiB;
          }
          // lib.optionalAttrs (cfg.acceleration == "cuda") {
            # Load kernels as they are first used rather than mapping every module in the
            # binary at startup - a meaningful cut in both start latency and VRAM floor on a
            # card this size, and it is the default from CUDA 12.2 on anyway.
            CUDA_MODULE_LOADING = "LAZY";
          }
          // lib.optionalAttrs (cfg.rocmGfxOverride != null) {
            HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfxOverride;
          };

        # ROCm has no CDI spec to lean on; the kernel driver's nodes are passed by hand.
        devices = lib.optionals (cfg.acceleration == "rocm") ["/dev/kfd" "/dev/dri"];

        extraOptions =
          [
            # Host networking keeps `--host 127.0.0.1` meaning the host's loopback, so the
            # proxies, LiteLLM and the health poll all reach the server exactly as they did
            # natively, with no port publishing to keep in sync with PORTS.
            "--network=host"
            # vLLM's worker processes share tensors over /dev/shm, and Docker's default 64 MiB
            # segment is far too small for it; upstream's own instructions use the host's IPC.
            "--ipc=host"
          ]
          ++ lib.optionals (gpuFlag != null) (lib.toList gpuFlag)
          ++ lib.optionals (cfg.acceleration == "rocm") [
            "--group-add=video"
            "--security-opt=seccomp=unconfined"
          ];
      })
    instances;

    # On-demand loading is systemd's socket-activation recipe rather than anything vLLM knows
    # how to do: vLLM has no idle timeout and no lazy-load mode, so the lifecycle is managed
    # from outside. Per instance there are three units:
    #
    #   vllm-<n>.socket        holds the public port open at all times, and starts the proxy on
    #                          the first connection
    #   vllm-<n>-proxy.service systemd-socket-proxyd, which pulls in the real server, forwards
    #                          the connection to it, and exits once --exit-idle-time passes with
    #                          nothing connected
    #   vllm-<n>.service       the container itself, bound to a private port, StopWhenUnneeded
    #                          so it goes away with the proxy that was the only thing needing it
    #
    # The cost is that the first request after an idle period blocks for as long as the model
    # takes to load; the proxy's ExecStartPre is what holds it there rather than failing it.
    systemd.sockets = lib.optionalAttrs lazy (lib.mapAttrs' (name: instance:
      lib.nameValuePair "vllm-${name}" {
        description = "Socket for on-demand vLLM server ${name}";
        wantedBy = ["sockets.target"];
        socketConfig = {
          # All addresses, not loopback: LiteLLM on another host reaches this port over Tailscale.
          # The firewall opens it on tailscale0 only (see networking.firewall below), so the LAN
          # still cannot connect. Binding the Tailscale IP itself would fail whenever the socket
          # starts before tailscaled has brought the interface up.
          ListenStream = "0.0.0.0:${toString instance.port}";
          # No activation rate limit. When the server behind the proxy fails to start, every new
          # connection re-triggers the proxy, and LiteLLM's retries from another host produce
          # those in bursts. At the default of 20 activations per 2s the socket then drops into
          # `trigger-limit-hit`, stops listening, and stays closed until restarted by hand - so
          # one broken model left its port refusing connections long after the cause was fixed.
          # The server's own RestartSec already throttles how often a failing model is retried.
          TriggerLimitIntervalSec = 0;
          # Names differ, so the socket has to be told which unit it activates - the default
          # would be the identically-named vllm-<n>.service, bypassing the proxy entirely.
          Service = "vllm-${name}-proxy.service";
        };
      })
    instances);

    systemd.services =
      lib.optionalAttrs (prefetchNames != []) {
        vllm-fetch-models = {
          description = "Download vLLM model weights from Hugging Face";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target"];
          wants = ["network-online.target"];

          environment = {
            HF_HOME = "${stateDir}/huggingface";
            HF_HUB_CACHE = hfCache;
          };

          serviceConfig = {
            # Not oneshot. A oneshot's start job lasts until the download finishes, and
            # multi-user.target orders itself after every unit it wants, so boot - and every
            # `nixos-rebuild switch`, which waits on that target - would hang for as long as tens
            # of gigabytes take to arrive. With exec the start job completes as soon as the script
            # is running; RemainAfterExit keeps the unit active afterwards, so a rebuild that
            # changes the catalogue still restarts it, and snapshot_download skips whatever is
            # already cached and fetches only the new entries.
            Type = "exec";
            RemainAfterExit = true;
            StateDirectory = "vllm";
            WorkingDirectory = stateDir;
            ExecStart = fetchScript;
            LoadCredential = lib.optional (cfg.hfTokenFile != null) "hf-token:${cfg.hfTokenFile}";
            # Redundant for exec in steady state, but a switch from an older oneshot definition
            # reloads the unit mid-download, and the fresh 90s default was then applied to the
            # run already in progress and killed it.
            TimeoutStartSec = "infinity";

            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
            UMask = "0077";
          };
        };
      }
      # The idle proxy in front of each server. Only exists in lazy mode; with idleTimeout null
      # the server binds the public port itself and none of this is in the path.
      // lib.optionalAttrs lazy (lib.mapAttrs' (name: instance:
        lib.nameValuePair "vllm-${name}-proxy" {
          description = "On-demand activation proxy for vLLM server ${name}";
          requires = ["vllm-${name}.socket" "vllm-${name}.service"];
          after = ["vllm-${name}.socket" "vllm-${name}.service"];
          # Evict every other instance on this host when this one is woken - see `exclusive`.
          conflicts = lib.optionals cfg.exclusive (
            map (other: "vllm-${other}-proxy.service") (lib.filter (other: other != name) servedNames)
          );

          serviceConfig = {
            # systemd-socket-proxyd inherits the listening socket from the .socket unit and
            # forwards to the server's private port, exiting once nothing has been connected
            # for --exit-idle-time. Its exit is what lets StopWhenUnneeded unload the model.
            #
            # `After=vllm-<n>.service` only means `docker run` was spawned, not that vLLM is
            # answering: it spends minutes pulling the image and loading weights before it binds.
            # Without the poll the proxy would forward the very first request into a closed port
            # and the client would see a connection reset instead of a slow response.
            #
            # The poll lives in ExecStart, not ExecStartPre, so the unit counts as started at
            # once. As a start-pre step it made the start job last as long as the whole image
            # pull and model load, and `nixos-rebuild switch` restarts a changed proxy and waits
            # on exactly that job - hanging the switch for as long as a cold model takes.
            # Clients still wait the same: their connections sit in the socket's backlog until
            # proxyd accepts them. `exec` keeps the PID, so LISTEN_PID still matches and proxyd
            # picks up the socket systemd passed in.
            ExecStart = pkgs.writeShellScript "vllm-${name}-proxy" ''
              until ${pkgs.curl}/bin/curl -sfo /dev/null http://127.0.0.1:${toString instance.backendPort}/health; do
                sleep 1
              done
              exec ${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${toString cfg.idleTimeout}s 127.0.0.1:${toString instance.backendPort}
            '';

            # Stateless, so there is nothing a stable uid would need to own.
            DynamicUser = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
            UMask = "0077";
          };
        })
      instances)
      # Additions on top of the unit oci-containers generates for each container, which already
      # brings Restart=on-failure, an unlimited start timeout and a 120s stop timeout - the
      # latter matters in lazy mode, where shutdown is routine and a model mid-load is slow to
      # respond to it.
      // lib.mapAttrs' (name: instance:
        lib.nameValuePair "vllm-${name}" {
          description = "vLLM server for ${name} (${instance.model.repo})";
          # Only orders the start relative to the prefetch unit's launch; it does not wait for the
          # download (see Type = "exec" there). A server woken while its model is still arriving
          # downloads it itself, and huggingface_hub's per-file locks in the shared cache make
          # the two wait on each other rather than fetch the same blob twice.
          after = lib.optional (prefetchNames != []) "vllm-fetch-models.service";
          # `wants`, not `requires`: a failed prefetch (rate limit, expired token) should leave
          # the servers whose weights are already cached running rather than take them down too.
          wants = lib.optional (prefetchNames != []) "vllm-fetch-models.service";
          # With no proxies to carry it (idleTimeout null), exclusivity has to sit on the
          # servers themselves; in lazy mode it lives on the proxies instead so that stopping
          # one lets StopWhenUnneeded unload the server behind it.
          conflicts = lib.optionals (cfg.exclusive && !lazy) (
            map (other: "vllm-${other}.service") (lib.filter (other: other != name) servedNames)
          );
          unitConfig = mkIf lazy {StopWhenUnneeded = true;};

          serviceConfig =
            {
              # Created before docker bind-mounts it, so a first boot doesn't get a
              # docker-created directory with whatever defaults the daemon picks.
              StateDirectory = "vllm";
              RestartSec = 30;
            }
            // lib.optionalAttrs (cfg.hfTokenFile != null) {
              LoadCredential = "hf-token:${cfg.hfTokenFile}";
              RuntimeDirectory = "vllm-${name}";
              RuntimeDirectoryMode = "0700";
              ExecStartPre = [(writeTokenEnvScript name)];
            };
        })
      instances
      # nixos-rebuild does not apply changes to .socket units: switch-to-configuration's branch for
      # them is literally `// FIXME: do something?` (nixpkgs#74899; the fix in #141192 was
      # reverted). A socket is only restarted when a running service of the same base name drags
      # it along - here that is the vllm-<n>.service container, which is idle most of the time.
      # So a changed ListenStream stays unapplied: the unit file says the new address while the
      # old listener is kept or lost, and LiteLLM on another host gets connection refused. Ports
      # follow the alphabetical order of the catalogue, so merely adding a model moves every port
      # after it and triggers this.
      #
      # This oneshot carries every socket's address in its restart triggers. It is an ordinary
      # service, which switch-to-configuration does restart when its unit changes, and restarting
      # it re-binds each socket whose proxy is not running. Sockets with an active proxy are left
      # alone so an in-flight request is not cut off; those are restarted by the switch through
      # their running container anyway. --no-block, because a blocking systemctl call from inside
      # a job the switch is waiting on would deadlock it.
      // lib.optionalAttrs lazy {
        vllm-sockets-reload = {
          description = "Re-bind vLLM activation sockets after their addresses change";
          wantedBy = ["multi-user.target"];
          after = map (name: "vllm-${name}.socket") servedNames;
          # The sockets' whole rendered config, not just their addresses: any change to a socket
          # unit (TriggerLimitIntervalSec included) is equally ignored by the switch.
          restartTriggers = map (name: builtins.toJSON config.systemd.sockets."vllm-${name}".socketConfig) servedNames;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script =
            lib.concatMapStringsSep "\n" (name: ''
              if ! ${pkgs.systemd}/bin/systemctl is-active --quiet vllm-${name}-proxy.service; then
                ${pkgs.systemd}/bin/systemctl restart --no-block vllm-${name}.socket
              fi
            '')
            servedNames;
        };
      };

    # Each instance's public port is reachable from the host itself and from the tailnet, never
    # from the LAN. Clients are meant to go through LiteLLM (litellm.nix), which fans a model name
    # out across every host serving it; the per-instance ports exist for LiteLLM and for local
    # consumers such as Hermes, not as a public API.
  };
}
