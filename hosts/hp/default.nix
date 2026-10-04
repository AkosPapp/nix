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
  # MODULES.networking.traefik.services.cups = "127.0.0.1:${toString config.PORTS.cups}";

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
  # https://litellm.hp that goes in a client config.
  MODULES.services.litellm.enable = true;
  # Where requests land when the only host serving a name is unreachable. litellm.nix builds those
  # fallbacks for every name no local host has, which is most of legion5's catalogue (coder,
  # gpt-oss, heretic): with the laptop shut they answer from this host's local/small-text instead
  # of erroring. Of the entries here it is the cheap one, and a degraded reply beats a failure.
  MODULES.services.litellm.fallbackModel = "local/small-text";
  # Wildcard OpenRouter passthrough - see litellm.nix. Key comes from the openrouter_api_key sops
  # secret.
  MODULES.services.litellm.openrouterEnable = true;
  # Second gateway, managed from its own dashboard (https://omniroute.hp) rather than
  # declared here: hosted providers and combos live in its database. The first-login password is
  # in /var/lib/omniroute/secrets.env (INITIAL_PASSWORD) - see omniroute.nix.
  MODULES.services.omniroute.enable = true;
  # Wildcard passthrough the other way: OmniRoute's own dashboard-managed providers/combos,
  # reachable through LiteLLM as "omniroute/<name>" - see litellm.nix. omniroute_api_key has to
  # be created by hand from OmniRoute's dashboard first (its module has no sops key to auto-fill
  # - see the option's doc comment), then added to sops under that name.
  MODULES.services.litellm.omnirouteEnable = true;
  MODULES.services.litellm.omnirouteApiKeySecret = "omniroute_api_key";
  # Third gateway, the Aqueduct instance self-hosted at https://futurelab.robo4you.at: wildcard
  # passthrough the same way again, so its models are reachable through LiteLLM as
  # "futurelab/<name>" - see litellm.nix. Nothing about it is on the tailnet, it is reached over
  # the public internet like OpenRouter is, and the models listed are discovered from Aqueduct's
  # own /v1/models, i.e. whatever its dashboard
  # (https://futurelab.robo4you.at/aqueduct/management/) has configured.
  #
  # futurelab_api_key has to be created by hand first, from the Tokens page of that dashboard,
  # since it sits behind the gateway's own login and nothing here can mint one - the same
  # manual-step situation omniroute's key is in.
  MODULES.services.litellm.futurelabEnable = true;
  MODULES.services.prometheus.enable = true;

  # MCP gateway/registry: remote MCP servers (devcontainers, other hosts) tunnel their local
  # stdio servers in over an outbound WebSocket (see mcp-switchboard.nix), and the hub aggregates
  # whatever's currently connected behind one Streamable HTTP /mcp endpoint.
  MODULES.services.mcp-switchboard.enable = true;
  # Agent-building UI: LLM calls go through the gateway above, MCP tools through the switchboard
  # hub's /mcp endpoint (n8n.nix). apiKeySecret stays unset until the one-time manual step
  # n8n.nix's `apiKeySecret` option documents (create a Public API key from n8n's own UI, since
  # nothing can mint one before a human has logged in once) - until then it comes up with no
  # pre-created credentials, which is still a fully usable instance.
  MODULES.services.n8n.enable = true;
  MODULES.services.n8n.ownerEmail = "it.akos.papp@gmail.com";
  MODULES.services.n8n.sandbox.enable = true;
  # AI Assistant/Agent code-execution sandbox (privileged Docker-in-Docker runner) - see
  # n8n-sandbox.nix's enable option before running this alongside anything else on this host.
  MODULES.services.n8n-sandbox.enable = true;

  # Second chat UI, alongside Open WebUI: MCP tools through the same switchboard hub /mcp
  # endpoint n8n uses above, native in LibreChat's own agent/tool support rather than n8n's
  # workflow-node model - see librechat.nix.
  MODULES.services.librechat.enable = true;

  # Personal agent stack - see RUNBOOK-hermes.md next to this file for the manual steps (sops
  # secrets, bridge logins, OAuth). A private Matrix server with federation off, reachable only
  # over the tailnet (https://matrix.hp, Element at https://element.hp); the mautrix bridges put
  # WhatsApp, Signal and Slack chats into it; Hermes talks to akos there and can read the bridged
  # rooms it is invited to.
  MODULES.services.matrix.enable = true;
  MODULES.services.mautrix = {
    whatsapp.enable = true;
    signal.enable = true;
    slack.enable = true;
  };
  MODULES.services.hermes-agent.enable = true;
  # Fill these in once the Entra app exists (runbook step 6) - himalaya stays out until then.
  # MODULES.services.hermes-agent.outlook = {
  #   address = "you@outlook.com";
  #   clientId = "00000000-0000-0000-0000-000000000000";
  #   tenant = "consumers";
  # };

  # Outline was tried and dropped - not needed. Its data (Postgres's "outline" database,
  # /var/lib/outline) was removed by hand on the host; see git history for how it was set up if
  # it comes back. mdbook (public docs) is unrelated and stays on.
  MODULES.services.outline.enable = false;

  # Public (Tailscale Funnel -> Traefik's `public` entry point) at https://hp.tail546fb.ts.net:8443/mdbook,
  # behind a git.robo4you.at login - see RUNBOOK-public.md. The docs follow the baumit-docs
  # package through a Forgejo webhook (same runbook).
  MODULES.services.mdbook.enable = true;
  # Client ID and secret come from sops (idp/client_id, idp/client_secret).
  MODULES.security.idp.enable = true;

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
