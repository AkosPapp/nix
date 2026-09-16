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
  # hp is the CPU worker as well as the gateway: it serves catalogue names legion5 also serves, so
  # LiteLLM treats them as replicas of one model and keeps answering - slowly, on four Zen+ cores -
  # while the laptop is shut. Weight 1 against legion5's 8 decides how the traffic splits when both
  # are up.
  #
  # GGUF quants rather than full-precision weights: small-text is a ~2.5 GB Q4_K_M whose q8_0 cache
  # is sized to the configured context, which is what makes 8192 tokens affordable beside Immich
  # ML, Prometheus, Loki, Grafana and Traefik on this 21 GiB machine. One model resident at a time
  # (maxLoadedModels default), two parallel slots each.
  MODULES.services.ollama.enable = true;
  MODULES.services.ollama.models = {
    small-text = {
      source = "qwen3:4b-instruct-2507-q4_K_M";
      contextLength = 16384;
    };
  };

  # hp is the always-on node, so the gateway lives here rather than on the laptop, and it is
  # hp's Tailscale name that goes in a client config.
  MODULES.services.litellm.enable = true;
  # Where requests land when the only host serving a name is unreachable. litellm.nix builds those
  # fallbacks for every name no local host has, which is most of legion5's catalogue (coder,
  # gpt-oss, heretic): with the laptop shut they answer from this host's small-text instead of
  # erroring. Of the entries here it is the cheap one, and a degraded reply beats a failure.
  MODULES.services.litellm.fallbackModel = "small-text";
  # The admin UI lives on the gateway's own tailscale-serve origin, at
  # https://hp.tail546fb.ts.net:8095/litellm/ui, not on the shared Traefik origin - "/" there is
  # the root redirect and 404 catch-all every subpath app relies on, so it can't be handed to one
  # app. No Traefik route, but the /litellm prefix stays via rootPath (SERVER_ROOT_PATH); the API
  # is unaffected and still answers at the origin root.
  MODULES.services.litellm.traefikPath = null;
  MODULES.services.litellm.rootPath = "/litellm";
  MODULES.services.prometheus.enable = true;

  # MCP gateway/registry: custom MCP servers (devcontainers, other hosts) register against its
  # API with a bearer token minted after first start (see mcp-context-forge.nix for where), and
  # it aggregates whatever's currently registered behind one virtual-server MCP endpoint.
  MODULES.services.mcp-context-forge.enable = true;
  # Agent-building UI: LLM calls go through the gateway above, MCP tools through Context Forge's
  # virtual server. apiKeySecret stays unset until the one-time manual step n8n.nix's
  # `apiKeySecret` option documents (create a Public API key from n8n's own UI, since nothing
  # can mint one before a human has logged in once) - until then it comes up with no
  # pre-created credentials, which is still a fully usable instance.
  MODULES.services.n8n.enable = true;
  MODULES.services.n8n.ownerEmail = "it.akos.papp@gmail.com";
  MODULES.services.n8n.sandbox.enable = true;

  MODULES.services.sftpgo.enable = true;
  MODULES.services.i2pd.enable = false;
  MODULES.services.immich.machineLearning.enable = true;
  # MODULES.services.transmission.enable = true;
  MODULES.services.searx.enable = true;
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
