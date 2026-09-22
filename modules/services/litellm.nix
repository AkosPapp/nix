{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.litellm;

  # Database and role share a name so ensureDBOwnership can tie them together.
  dbName = "litellm";

  # Same auto-discovery pattern as immich.nix: every host in the flake is inspected, and the
  # ones running vLLM or Ollama contribute their catalogues here. Adding a model to a host's
  # catalogue is therefore the only edit needed - the gateway's routing table follows from it,
  # and there is no second list of endpoints to keep in step. The two runtimes are otherwise
  # independent; this gateway is the one place they meet, and a name served by both - on one host
  # or several - simply becomes more replicas of that model.
  allHostNames = builtins.attrNames nixosConfigurations;
  hostConfig = host: nixosConfigurations.${host}.config;
  hostVllm = host: (hostConfig host).MODULES.services.vllm;
  hostOllama = host: (hostConfig host).MODULES.services.ollama;

  vllmHosts = builtins.filter (host: (hostVllm host).enable) allHostNames;
  ollamaHosts = builtins.filter (host: (hostOllama host).enable) allHostNames;
  backendHosts = lib.unique (vllmHosts ++ ollamaHosts);

  # Whether any backend is started on demand rather than held resident. Decides whether probing
  # deployments on a timer is harmless monitoring or an alarm clock - see general_settings.
  # Ollama always is: keep_alive unloads idle models, and a health probe would load them again.
  anyLazyBackend =
    ollamaHosts
    != []
    || lib.any (host: (hostVllm host).idleTimeout != null) vllmHosts;

  # The local host's own servers are on loopback; everyone else's are reached over Tailscale,
  # which is the only network these machines share.
  hostAddress = host:
    if host == configName
    then "127.0.0.1"
    else (hostConfig host).MODULES.networking.tailscale.hostIP;

  # One LiteLLM deployment per (host, model). Two hosts serving the same catalogue entry produce
  # two deployments under one `model_name`, which is exactly what the router wants: it treats
  # them as interchangeable replicas and moves traffic to the survivor when one stops answering.
  deploymentsFor = host:
    lib.mapAttrsToList (name: instance: {
      model_name = name;
      litellm_params = {
        # `hosted_vllm/` is LiteLLM's provider prefix for a vLLM OpenAI-compatible server; the
        # part after it is the name vLLM itself serves the model under (--served-model-name).
        model = "hosted_vllm/${instance.model.servedName}";
        api_base = "http://${hostAddress host}:${toString instance.port}/v1";
        # vLLM checks no key - its ports are reachable only from the host and the tailnet - but
        # the OpenAI client library refuses to send a request without something in the field.
        api_key = "unused";

        # Long, because the request that wakes a sleeping instance blocks for the whole model
        # load - see MODULES.services.vllm.idleTimeout. This is also the reason a host being
        # down cannot simply be inferred from slowness: the two look identical for the first
        # minute, which is what the cooldowns below are for.
        timeout = cfg.requestTimeout;

        # Relative share of the traffic for this model_name. Only has an effect where more
        # than one host serves the entry, which is the case worth configuring: the router
        # dispatches concurrent requests to both, and without a weight it would send as many
        # to the CPU host as to the GPU one.
        # No per-deployment num_retries, deliberately. LiteLLM's router replaces the request's
        # retry count with a failing deployment's own value, so num_retries = 0 on a remote host
        # did not mean "don't retry this host" - it cancelled the router-level retry that moves
        # the request to another host's replica, and a legion5 that refused the connection
        # became a 500 even though hp serves the same model. A dead host is taken out of
        # rotation after one failure instead (allowedFails), so the retry lands elsewhere.
        weight = (hostVllm host).weight;
      };

      model_info = {
        # Stable, unique per deployment so cooldowns are applied to the one host that failed
        # rather than to the model name as a whole.
        id = "${host}-${name}";
        inherit host;
      };
    })
    (hostVllm host).instances;

  # One deployment per (host, Ollama model). `ollama_chat/` is LiteLLM's native Ollama provider,
  # which speaks /api/chat and passes tools and images through; api_base is the server root, not
  # /v1. The model is the catalogue name, which ollama.nix creates from its Modelfile with the
  # entry's context baked in - so nothing per request (num_ctx) has to be sent from here.
  ollamaDeploymentsFor = host: let
    ollama = hostOllama host;
  in
    lib.mapAttrsToList (name: _: {
      model_name = name;
      litellm_params = {
        model = "ollama_chat/${name}";
        api_base = "http://${hostAddress host}:${toString (hostConfig host).PORTS.ollama}";
        # Long for the same reason as vLLM's: the request that finds the model unloaded waits
        # for it to load, and on a CPU host for a long prefill besides.
        timeout = cfg.requestTimeout;
        inherit (ollama) weight;
      };
      model_info = {
        # Distinct from a vLLM deployment of the same name on the same host, so cooldowns hit
        # the runtime that failed.
        id = "${host}-ollama-${name}";
        inherit host;
      };
    })
    ollama.models;

  deployments =
    lib.concatMap deploymentsFor vllmHosts
    ++ lib.concatMap ollamaDeploymentsFor ollamaHosts;

  modelNamesOn = host:
    lib.optionals (hostVllm host).enable (lib.attrNames (hostVllm host).instances)
    ++ lib.optionals (hostOllama host).enable (lib.attrNames (hostOllama host).models);

  localModels =
    if builtins.elem configName backendHosts
    then lib.unique (modelNamesOn configName)
    else [];

  allModels = lib.unique (lib.sort (a: b: a < b) (lib.concatMap modelNamesOn backendHosts));

  # Models this host cannot serve itself. If the only host that has one goes down there is no
  # replica to fail over to, so they get an explicit fallback onto something local: a degraded
  # answer from the small CPU model beats a connection error.
  remoteOnlyModels = builtins.filter (m: !(builtins.elem m localModels)) allModels;

  fallbackTarget =
    if cfg.fallbackModel != null
    then cfg.fallbackModel
    else if localModels != []
    then builtins.head (lib.sort (a: b: a < b) localModels)
    else null;

  fallbacks =
    lib.optionals (fallbackTarget != null)
    (map (m: {${m} = [fallbackTarget];})
      (builtins.filter (m: m != fallbackTarget) remoteOnlyModels));

  # The proxy's config.yaml, rendered into the store and bind-mounted into the container. Nothing
  # secret goes in here: the master key is an os.environ/ indirection LiteLLM resolves at startup.
  settings = {
    model_list = deployments;

    router_settings = {
      routing_strategy = cfg.routingStrategy;

      inherit (cfg) allowedFails cooldownTime;

      # Retries are what turn "legion5 is off" into a served request: the first attempt goes
      # to whichever replica was shuffled first, and on failure the router moves to the next
      # host's copy rather than reporting the error.
      num_retries = 2;

      # Only retry the errors that another host could plausibly answer. Retrying a 400 from
      # a malformed request against every deployment in turn just multiplies the failure.
      retry_policy = {
        TimeoutErrorRetries = 2;
        RateLimitErrorRetries = 2;
        InternalServerErrorRetries = 2;
        ContentPolicyViolationErrorRetries = 0;
        AuthenticationErrorRetries = 0;
        BadRequestErrorRetries = 0;
      };

      inherit fallbacks;
    };

    litellm_settings =
      {
        request_timeout = cfg.requestTimeout;
        # Drop a deployment's cached client when it errors, so a host that went away and came
        # back on a different path is not talked to over a dead connection.
        drop_params = true;
        set_verbose = false;
      }
      // lib.optionalAttrs cfg.metrics {
        # Mounting /metrics is a side effect of registering the callback - there is no
        # separate switch for the endpoint.
        callbacks = ["prometheus"];
      };

    general_settings =
      {
        # Off whenever anything behind the gateway is socket-activated, which is the normal
        # case here. A background health check opens a connection to every deployment on a
        # timer, and against an on-demand instance that connection *is* the wake-up: the
        # model loads, answers the probe, idles out, and loads again on the next sweep -
        # turning "only resident when someone is using it" into a permanent reload cycle
        # that never serves a real request. Losing it costs little, since the router already
        # discovers a dead host through `allowedFails` on real traffic.
        background_health_checks = !anyLazyBackend;
      }
      // lib.optionalAttrs (!anyLazyBackend) {
        health_check_interval = 300;
      }
      // lib.optionalAttrs (cfg.masterKeySecret != null || cfg.environmentFile != null) {
        # Read at startup from the environment file rather than written into the config in
        # the store. LiteLLM resolves this indirection itself.
        master_key = "os.environ/LITELLM_MASTER_KEY";
      };
  };
in {
  options.MODULES.services.litellm = {
    enable = mkEnableOption ''
      the LiteLLM proxy, a single OpenAI-compatible endpoint in front of every vLLM instance in
      the flake. It auto-discovers them: any host with MODULES.services.vllm.enable contributes
      its whole catalogue, local ones over loopback and remote ones over Tailscale.

      Where two hosts serve the same catalogue entry, their instances become replicas of one
      model name and the router spreads concurrent requests across both machines in the
      proportions set by each host's MODULES.services.vllm.weight - so parallel load really does
      run on several GPUs at once, and one host going down costs throughput rather than
      availability. Entries only one host serves have no replica to spread onto and rely on
      `fallbackModel` instead
    '';

    requestTimeout = mkOption {
      type = types.int;
      default = 900;
      description = ''
        Seconds LiteLLM waits for a vLLM instance before giving up on it. Deliberately large:
        with on-demand loading the first request to an idle instance pays the model's entire
        load time, and a timeout tuned for a warm server would abort exactly the requests that
        are supposed to be slow. The cost of the generous value is that a genuinely wedged
        backend also occupies a slot for this long, which `allowedFails` limits the damage from.
      '';
    };

    allowedFails = mkOption {
      type = types.int;
      default = 1;
      description = ''
        Failures a single deployment may accumulate before the router takes it out of rotation
        for `cooldownTime`. One, because the common failure here is a whole host being off
        rather than a flaky request: there is nothing to be gained by discovering that twice.
      '';
    };

    cooldownTime = mkOption {
      type = types.int;
      default = 60;
      description = ''
        Seconds a failed deployment stays out of rotation before the router will try it again.
        Short enough that a host coming back is picked up without intervention, long enough that
        a host which is off does not have every request stall on it first.
      '';
    };

    routingStrategy = mkOption {
      type = types.enum [
        "simple-shuffle"
        "least-busy"
        "latency-based-routing"
        "usage-based-routing-v2"
      ];
      default = "simple-shuffle";
      description = ''
        How the router picks between the deployments that share a `model_name` - which is what
        makes concurrent requests to one model fan out across hosts instead of queueing on one.
        Every host serving a given catalogue entry contributes a deployment under that name, so
        this only has anything to choose between for models more than one host serves; a model
        only legion5 has goes to legion5 whatever this says.

        "simple-shuffle" picks at random in the proportions set by each host's
        MODULES.services.vllm.weight, and is the default for two reasons. It is the only
        strategy that reads `weight` at all - LiteLLM honours that key in simple_shuffle and
        nowhere else, so under any other setting the weights silently stop applying and a CPU
        host gets the same share as a GPU one. And it is the only one that does not
        systematically prefer a cold instance: the backends here are socket-activated, so an
        unloaded model reports zero in-flight requests and zero latency, which is exactly the
        profile "least-busy" and "latency-based-routing" chase - they would steer traffic
        towards whichever replica is asleep and pay a full model load to do it.

        The load-aware strategies become the better choice if idleTimeout is ever set to null,
        where every instance is always resident and those signals mean what they claim to.

        Note this is only the outer layer of parallelism. vLLM batches concurrent requests
        inside a single instance continuously, so one instance already serves many at once -
        spreading across hosts adds throughput on top of that rather than being what makes
        concurrency possible.
      '';
    };

    fallbackModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "qwen3-4b";
      description = ''
        Model to answer with when the request named one that only a now-unreachable host serves.
        Null picks the alphabetically first locally-served model, which is the right instinct on
        a gateway host that also runs its own CPU instances; set it explicitly to choose a
        better-suited one. Models served by more than one host never reach this - the router
        already treats those hosts as replicas of each other.
      '';
    };

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = ''
        Enable LiteLLM's "prometheus" callback, which mounts a /metrics endpoint carrying
        per-model request counts, latency histograms, token totals and - the useful part for
        this stack - deployment state, so a host that has been cooled out of rotation is
        visible rather than merely slow. Not a premium feature despite much of LiteLLM's
        observability being so, and `prometheus-client` is already in the package's closure.
      '';
    };

    masterKeySecret = mkOption {
      type = types.nullOr types.str;
      default =
        if config.MODULES.security.sops.enable
        then "litellm_master_key"
        else null;
      defaultText = lib.literalExpression ''if MODULES.security.sops.enable then "litellm_master_key" else null'';
      description = ''
        Name of the sops secret holding the bare master key, rendered into the service's
        environment as LITELLM_MASTER_KEY. The key is what requires an Authorization header on
        every request - without it the proxy is open to anything that can reach the tailnet -
        and the admin UI refuses to load at all without one. It is also the UI's login password
        unless UI_PASSWORD is set. By convention it starts with "sk-", like the virtual keys the
        proxy mints from it.

        Null leaves the key to `environmentFile`.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/litellm/env";
      description = ''
        Extra environment file for the service, in KEY=value form, for anything beyond the
        master key (UI_PASSWORD, provider API keys). With `masterKeySecret` null it can carry
        LITELLM_MASTER_KEY itself. A path rather than the value, so it stays out of the
        world-readable Nix store.
      '';
    };

    uiUsername = mkOption {
      type = types.str;
      default = "admin";
      description = ''
        Username for LiteLLM's built-in admin UI. The password comes from UI_PASSWORD in
        `environmentFile`, and falls back to the master key when that is unset.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "ghcr.io/berriai/litellm-database:v1.86.0";
      description = ''
        Container image the gateway runs. The "-database" flavour, because it is the one that
        bundles the Prisma client and engines LiteLLM needs to reach Postgres - which the admin
        UI requires just to log in. Pinned to the same release nixpkgs 26.05 packaged, so moving
        off the native service changed where LiteLLM runs, not which LiteLLM runs. Bumping the
        tag is the upgrade path; LiteLLM applies any new schema migrations itself on start.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.fallbackModel == null || builtins.elem cfg.fallbackModel allModels;
        message = ''
          MODULES.services.litellm.fallbackModel is "${toString cfg.fallbackModel}", which no
          host in the flake serves. Every model that only one host has would be given a
          fallback onto a name the router cannot resolve, turning that host being down into a
          confusing error rather than a degraded answer. Known models: ${
            if allModels == []
            then "(none)"
            else lib.concatStringsSep ", " allModels
          }.
        '';
      }
      {
        assertion = backendHosts != [];
        message = ''
          MODULES.services.litellm.enable is set but no host in the flake has
          MODULES.services.vllm.enable or MODULES.services.ollama.enable - the proxy would start
          with an empty model list and answer 400 to everything.
        '';
      }
    ];

    # LiteLLM runs from upstream's database image rather than nixpkgs' native package. The admin
    # UI logs in by minting a key in Postgres, and the Prisma client LiteLLM reaches Postgres
    # through cannot run on NixOS: prisma-client-py 0.15 is pinned to Prisma 5.17 while nixpkgs
    # ships only 6.x and 7.x, Prisma publishes no engine binaries for NixOS, and
    # litellm-proxy-extras (the schema migrations) is not packaged. The image carries all of it
    # and applies the migrations itself on start.
    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    virtualisation.oci-containers.containers.litellm = {
      inherit (cfg) image;
      # Keeps the unit at litellm.service - the name open-webui.nix orders against and the sops
      # template restarts - instead of docker-litellm.service.
      serviceName = "litellm";
      # The image's entrypoint is `exec litellm "$@"`, so these are plain proxy flags.
      cmd = [
        "--config"
        "/app/config.yaml"
        "--host"
        "127.0.0.1"
        "--port"
        (toString config.PORTS.litellm)
      ];

      volumes = [
        "${(pkgs.formats.yaml {}).generate "litellm-config.yaml" settings}:/app/config.yaml:ro"
        # Postgres over its unix socket, authenticated by peer credentials (identMap below), so
        # there is no database password to generate, store or rotate.
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";

        UI_USERNAME = cfg.uiUsername;

        # Prisma's unix-socket form: the host part is ignored in favour of `host=`. LiteLLM
        # appends its own pool parameters to this with the existing query string preserved.
        DATABASE_URL = "postgresql://${dbName}@localhost/${dbName}?host=/run/postgresql";
      };

      environmentFiles =
        lib.optional (cfg.masterKeySecret != null) config.sops.templates."litellm.env".path
        ++ lib.optional (cfg.environmentFile != null) cfg.environmentFile;

      # Host networking: the vLLM backends are on this host's loopback and on other hosts'
      # Tailscale addresses, and Traefik, tailscale serve and Prometheus all expect the gateway
      # on 127.0.0.1 - exactly as the native service was.
      extraOptions = ["--network=host"];
    };

    # postgresql.target, not postgresql.service: the target also covers postgresql-setup, which
    # is where ensureUsers creates the role. Ordering on the server alone would let LiteLLM
    # connect before its role exists and fail its migrations on first boot.
    systemd.services.litellm = {
      requires = ["postgresql.target"];
      after = ["postgresql.target"];
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [dbName];
      ensureUsers = [
        {
          name = dbName;
          ensureDBOwnership = true;
        }
      ];
      # The container runs as root and shares the host's uid namespace, so the socket's peer
      # credentials say "root". Map that to the litellm role for this one database only, rather
      # than handing root a way into every database.
      identMap = ''
        litellm root ${dbName}
      '';
      authentication = ''
        local ${dbName} ${dbName} peer map=litellm
      '';
    };

    sops.secrets = lib.mkIf (cfg.masterKeySecret != null) {
      ${cfg.masterKeySecret} = {};
    };

    # The secret is the bare key, but --env-file wants KEY=value lines, so it is wrapped here.
    # Root-owned 0400 is enough: the docker CLI in the unit runs as root and reads it before the
    # container starts.
    sops.templates."litellm.env" = lib.mkIf (cfg.masterKeySecret != null) {
      content = ''
        LITELLM_MASTER_KEY=${config.sops.placeholder.${cfg.masterKeySecret}}
      '';
      restartUnits = ["litellm.service"];
    };

    # API at the origin root (OpenAI SDKs append /v1/... to their base URL), admin UI at /ui.
    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.litellm = "127.0.0.1:${toString config.PORTS.litellm}";
  };
}
