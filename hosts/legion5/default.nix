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

  # Other hosts' Traefik zones (by default their host name: hp, akos01, ...) and the Tailscale IP
  # behind each. Generated from the flake, so a new host needs no edit here.
  tailnetZones = lib.filter (z: z.ip != null) (lib.mapAttrsToList (host: h: {
    domain = h.config.MODULES.networking.traefik.domain;
    ip = h.config.MODULES.networking.tailscale.hostIP;
  }) (lib.removeAttrs nixosConfigurations [configName]));

  # dnsmasq's dynamic include, regenerated on a timer. While tailscale is connected, its zone
  # (MagicDNS) is forwarded and every other host's zone resolves to that host's tailscale IP.
  # robo4you.at points at r4uai01's netbird IP only while its route leaves through wt0 and it
  # answers the zone; otherwise none of those lines exist and dnsmasq falls through to the public
  # servers. The file is only replaced (and dnsmasq restarted) when its contents change.
  splitDns = pkgs.writeShellScript "split-dns" ''
    export PATH="${lib.makeBinPath [
      config.systemd.package
      config.services.tailscale.package
      config.services.netbird.package
      pkgs.coreutils
      pkgs.jq
      pkgs.iproute2
      pkgs.dnsutils
      pkgs.diffutils
    ]}"

    conf=/run/dnsmasq.d/split.conf
    mkdir -p "$(dirname "$conf")"

    netbird_dns=100.124.160.88
    netbird_zone=robo4you.at

    # tailscale0 survives `tailscale down`, so ask the backend instead of the interface.
    tailscale_up=0
    if ip link show dev tailscale0 up >/dev/null 2>&1; then
      state=$(timeout 2 tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') || state=
      if [ "$state" = "Running" ]; then
        tailscale_up=1
      fi
    fi

    # wt0 having an address proves nothing: the daemon can sit disconnected for hours with the
    # interface left in place, and every query dnsmasq forwards into it blackholes - including
    # netbird's own lookup of its management host, which turns one dropout into a permanent
    # lockout. Ask the daemon instead: connected to Signal AND at least one relay available or
    # one peer connected (peers legitimately sit Idle on a lazy mesh, so relays carry most of
    # the "data plane alive" vote). Only then the zone probe still has to answer.
    netbird_up=0
    if ip link show dev wt0 up >/dev/null 2>&1; then
      nb=$(timeout 3 netbird status --json 2>/dev/null | jq -r \
        '[.signal.connected // false, (.relays.available // 0), (.peers.connected // 0)] | @tsv') || nb=
      case "$nb" in
        true*)
          route=$(ip route get "$netbird_dns" 2>/dev/null) || route=
          case " $route " in
            *" dev wt0 "*)
              relays=$(cut -f2 <<<"$nb")
              peers=$(cut -f3 <<<"$nb")
              if [ "$relays" -gt 0 ] 2>/dev/null || [ "$peers" -gt 0 ] 2>/dev/null; then
                if [ -n "$(dig +time=1 +tries=3 +short "@$netbird_dns" "$netbird_zone" SOA 2>/dev/null)" ]; then
                  netbird_up=1
                fi
              fi
              ;;
          esac
          ;;
      esac
    fi

    {
      if [ "$tailscale_up" = 1 ]; then
        echo "server=/${config.MODULES.networking.tailscale.tailnetDnsName}/100.100.100.100"
        ${lib.concatMapStringsSep "\n    " (z: "echo 'address=/${z.domain}/${z.ip}'") tailnetZones}
      fi
      if [ "$netbird_up" = 1 ]; then
        echo "server=/$netbird_zone/$netbird_dns"
      fi
      # The tunnel must never have to resolve its own front door: robo4you.at routes into
      # netbird, so netbird.robo4you.at gets a permanent longest-match exception to the public
      # resolvers - emitted whether or not the zone line is present, so netbird's bootstrap
      # lookup can never depend on the connection it needs that lookup to establish.
      echo "server=/netbird.$netbird_zone/9.9.9.9"
      echo "server=/netbird.$netbird_zone/1.1.1.1"
    } > "$conf.new"

    if ! cmp -s "$conf.new" "$conf"; then
      mv "$conf.new" "$conf"
      systemctl restart dnsmasq
    else
      rm -f "$conf.new"
    fi
  '';

  # The timer above is the backstop; this is the fast path. `ip monitor` streams the same
  # netlink events udev sees, so a VPN interface, address or route landing (netbird's wt0,
  # tailscale's routes flushed on down) wakes the updater within ~1s instead of up to a poll
  # interval plus script runtime. One burst of events (a reconnect flaps several routes)
  # collapses to a single updater run, and `systemctl start` waits for it, serialising runs.
  splitDnsWatch = pkgs.writeShellScript "split-dns-watch" ''
    export PATH="${lib.makeBinPath [
      pkgs.iproute2
      config.systemd.package
      pkgs.coreutils
    ]}"
    while IFS= read -r _; do
      # Give whoever changed the network a beat to finish, drain the rest of the burst, then trigger.
      sleep 1
      while IFS= read -r -t 1 _; do :; done
      systemctl start split-dns.service || true
    done < <(exec ip monitor link address route)
  '';
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
    # Same model, dialled around hp when litellm.hp is unreachable: the futurelab Aqueduct
    # gateway takes the bare model id (only LiteLLM spells it "futurelab/..."). Picked by hand
    # in pi/opencode's model selector - nothing here fails over automatically. Key comes from
    # the futurelab_api_key sops secret (same one hp's litellm wildcard reads).
    backupProvider = {
      baseUrl = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key";
    };
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

  # PLAN §4: L1 snapshots + push of the persist dataset to hp (L2 side - this laptop is
  # the only box with state that hp does not already hold; hp schedules its own retention
  # of the received zroot/persist/legion5). §4.2's laptop row is 12/7/4: lighter than the
  # servers because the laptop is often off, and the finer 1h=>1min tier of the old hand
  # config only produced noise across suspend gaps.
  MODULES.system.znapzend = {
    enable = true;
    jobs = [
      {
        dataset = "zroot/root";
        plan = "12h=>1h,7d=>1d,4w=>1w";
      }
      {
        dataset = "zroot/persist/legion5";
        plan = "12h=>1h,7d=>1d,4w=>1w";
        destinations.hp = {
          host = "root@hp";
          dataset = "zroot/persist/legion5";
        };
      }
    ];
  };

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

  # One local resolver (dnsmasq) instead of systemd-resolved, because the split depends on
  # whether each VPN is actually usable:
  # - public backups, in the requested order: 9.9.9.9, 1.1.1.1, 8.8.8.8
  # - AirLab's DNS only for its zone (the DHCP-provided servers are otherwise ignored)
  # - Tailscale's MagicDNS and the other hosts' Traefik zones only while tailscale is connected
  # - robo4you.at via netbird's r4uai01 (100.124.160.88) only while wt0 is up, the route to it
  #   leaves through wt0, and it answers the zone. netbird's advertised 172.18.0.1 is this host's
  #   own docker bridge, and its DNS client is disabled in users/akos.nix.
  # The dynamic parts come from splitDns above; dnsmasq is restarted only when its include
  # actually changes.
  services.resolved.enable = false;

  services.dnsmasq = {
    enable = true;
    # modules/networking/dns.nix already runs this host's authoritative zone in dnsmasq and
    # deliberately keeps it off the system resolver; here we also want it to be the system
    # resolver, and to keep listening on the tailscale address for the authoritative zone.
    resolveLocalQueries = lib.mkForce true;
    settings = {
      # Never adopt the DHCP servers as defaults: the public list below is the fallback.
      no-resolv = lib.mkForce true;
      # `no-resolv` already ignores this; drop the module's marker to avoid a startup warning.
      resolv-file = lib.mkForce [];
      # The tailscale address may not exist yet when dnsmasq starts.
      bind-dynamic = lib.mkForce true;
      listen-address = lib.mkForce [
        "127.0.0.1"
        "::1"
        config.MODULES.networking.tailscale.hostIP
      ];
      strict-order = true;
      server = [
        "9.9.9.9"
        "1.1.1.1"
        "8.8.8.8"
        "/airlab/10.50.20.2"
      ];
      conf-dir = "/run/dnsmasq.d,*.conf";
    };
  };

  systemd.tmpfiles.rules = ["d /run/dnsmasq.d 0755 root root -"];

  systemd.services.split-dns = {
    description = "Regenerate dnsmasq's VPN-dependent split-DNS include";
    # A transient dnsmasq restart failure must not stop the timer from retrying.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${splitDns}";
    };
  };
  systemd.timers.split-dns = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5s";
      OnUnitActiveSec = "10s";
    };
  };

  systemd.services.split-dns-watch = {
    description = "Trigger split-dns immediately on interface/address/route changes";
    wantedBy = ["multi-user.target"];
    # `ip monitor` can die on a netlink buffer overrun; never let the start-limit give up on it.
    startLimitIntervalSec = 0;
    serviceConfig = {
      ExecStart = "${splitDnsWatch}";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Tailscale still provides the tailnet; dnsmasq forwards its zone explicitly.
  services.tailscale.extraSetFlags = lib.mkForce [
    "--accept-dns=false"
    "--accept-routes=true"
    "--advertise-exit-node=false"
  ];
}
