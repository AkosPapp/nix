{
  config,
  pkgs,
  lib,
  ...
}: let
  # PDF and JSON tooling for the Hermes agent, its cron jobs, and root's shell.
  # enableLanguages must be pinned: the tesseract wrapper's default is *every*
  # language (~1 GB of traineddata). eng is mandatory alongside (tessdata bug).
  agentTools = with pkgs; [
    poppler-utils # pdftotext, pdfimages, pdfinfo (attr renamed from poppler_utils)
    pdfgrep
    jq
    (tesseract.override {enableLanguages = ["eng" "deu"];}) # scanned-PDF OCR, German
    # This nixpkgs' plain ffmpeg is the full build (libx264/x265, freetype/drawtext),
    # verified against the locked flake's derivation - no need for ffmpeg-full here.
    ffmpeg
  ];
in {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  MODULES.services.syncthing.deviceID = "ST66PS2-5LYQY5J-LNI3FR4-3VLG7W3-F4ZHRS2-72NZMBG-QVWV2QD-6SB2DQF";
  # The notes graph, down here so the Hermes agent can read it. `path` stays legion5's path on
  # purpose: that string is the Syncthing folder ID *and* the peer-matching key (see
  # MODULES.services.syncthing.shares), which is what wires hp into the folder legion5 and the phone
  # already share. `override_path` is where hp keeps it. The phone is a direct peer too, so notes
  # arrive even while legion5 is switched off.
  MODULES.services.syncthing.shares = [
    {
      path = "/home/akos/notes";
      override_path = "/var/lib/notes";
      # copyOwnershipFromParent deliberately NOT set: it makes syncthing lchown pulled files to
      # the parent dir's owner:group, which an unprivileged syncthing cannot do into a group it is
      # not a member of (syncthing must never join `hermes`) -> every finalize fails with
      # "copy owner from parent: lchown: invalid argument" and the folder retries forever. The
      # 2755 setgid bit below already gives new files group=hermes through kernel inheritance,
      # which is all the agent's read access needs.
      extra_devices = ["phone"];
      # git stays on legion5; hp only wants the markdown. Ignore patterns are per-device, so this
      # doesn't change what legion5 and the phone exchange with each other.
      ignorePatterns = ["/.git"];
    }
  ];
  # hp's syncthing already runs as the `syncthing` uid for the grafana/prometheus shares, so the
  # notes folder goes next to those instead of under /var/lib/hermes: reaching a share inside
  # /var/lib/hermes would mean either the hermes group (2770 = *group writable*, so a network-facing
  # daemon could delete the agent's own state) or an execute-only POSIX ACL, which this ZFS dataset
  # does not support. It is world-readable for the same reason dashboardsDir is: the agent runs in a
  # user namespace, where foreign uids show up as nobody and only the `other` bits carry.
  systemd.tmpfiles.rules = [
    "d /var/lib/notes 2755 syncthing hermes - -"
    # The agent's own note folder (inside the share, so its notes sync like any other file).
    # The 2775 is the whole scope of its write access: every other directory in the share stays
    # 2755, so outside hermes/ the agent can create or replace nothing.
    "d /var/lib/notes/hermes 2775 syncthing hermes - -"
  ];
  # Per-session escalation for the whole share, run by hand as root - the agent has no root in
  # its sandbox and must not gain any: broad write access then exists only between an explicit
  # `grant` and the next `revoke`, and a reboot reasserts the tmpfiles modes anyway. No rebuild
  # involved, so it works while a chat session is live.
  environment.systemPackages =
    [
      (pkgs.writeShellScriptBin "hermes-notes-edit" ''
        set -eu

        if [ "$#" -lt 1 ]; then
          echo "usage: hermes-notes-edit grant|revoke|status" >&2
          exit 2
        fi

        # Everything in the share except syncthing's own state.
        walk() {
          find /var/lib/notes -not -path '*/.stfolder*' -not -name '.stignore' "$@"
        }

        case "$1" in
          grant)
            # g+w on directories lets the agent replace files; on files, edit them in place.
            # New folders synced in afterwards need another grant pass (status shows the damage).
            walk -type d -exec chmod g+w '{}' +
            walk -type f -exec chmod g+w '{}' +
            echo "granted: hermes can edit every file in the notes share"
            ;;
          revoke)
            walk -type d -exec chmod 2755 '{}' +
            walk -type f -exec chmod 644 '{}' +
            chmod 2775 /var/lib/notes/hermes
            echo "revoked: back to the agent's own hermes/ folder only"
            ;;
          status)
            if walk -mindepth 1 -type d -not -path '/var/lib/notes/hermes*' -perm -g+w | grep -q .; then
              echo "GRANTED: group-writable beyond hermes/:"
              walk -mindepth 1 -type d -perm -g+w
            else
              echo "locked: agent writes limited to /var/lib/notes/hermes"
            fi
            ;;
          *)
            echo "usage: hermes-notes-edit grant|revoke|status" >&2
            exit 2
            ;;
        esac
      '')
    ]
    ++ agentTools;
  # The agent's sandbox sees /var/lib/hermes and nothing else, so bind the share into it. The two
  # Hermes units get it read-write at the mount, but write access is carried by the file modes
  # instead: 2755 everywhere except /var/lib/notes/hermes (2775), so the kernel denies the agent
  # create/replace/delete anywhere else while `hermes-notes-edit grant` (above) can still widen it
  # for one session without a restart. matrix-reader keeps the hard read-only bind - it only ever
  # reads notes. The `-` prefix keeps the units up if the folder is ever missing.
  #
  # One agent-side rule this trades away nothing on but cannot be enforced by modes: the units run
  # UMask=0077, so a file the agent writes is 0600 and syncthing, reading as `other`, would never
  # see it. The agent's notes workflow chmods its own files 644 as it writes them.
  systemd.services = let
    notes-bind = "-/var/lib/notes:/var/lib/hermes/notes";
  in {
    # The Hermes units run with a closed PATH; environment.systemPackages is NOT in
    # it, so every tool the agent's terminal() or cron shells may execute has to be
    # listed on the unit itself (the systemd module appends these to the unit PATH).
    hermes-agent.path = agentTools;
    hermes-backend.path = agentTools;
    hermes-agent.serviceConfig.BindPaths = [notes-bind];
    hermes-backend.serviceConfig.BindPaths = [notes-bind];
    matrix-reader.serviceConfig.BindReadOnlyPaths = [notes-bind];
  };
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
  # The gateway itself, on the internet: https://hp.tail546fb.ts.net:8443/litellm/v1 through the
  # shared Funnel origin (see RUNBOOK-public.md). It exists for the Paseo installers - the machines
  # they install deliberately have no Tailscale, so https://litellm.hp is not an address they can
  # use - and for any other off-tailnet client. Only the OpenAI-compatible prefix gets a route: the
  # admin UI, its management API and /metrics stay tailnet-only, and what is public answers only to
  # a LiteLLM key (litellm_master_key, or a virtual key minted from it). See the `public` options in
  # litellm.nix.
  MODULES.services.litellm.public.enable = true;
  MODULES.services.prometheus.enable = true;

  # Agent-building UI: LLM calls go through the gateway above (n8n.nix). apiKeySecret stays unset until the one-time manual step
  # n8n.nix's `apiKeySecret` option documents (create a Public API key from n8n's own UI, since
  # nothing can mint one before a human has logged in once) - until then it comes up with no
  # pre-created credentials, which is still a fully usable instance.
  MODULES.services.n8n.enable = true;
  MODULES.services.n8n.ownerEmail = "it.akos.papp@gmail.com";
  MODULES.services.n8n.sandbox.enable = true;
  # AI Assistant/Agent code-execution sandbox (privileged Docker-in-Docker runner) - see
  # n8n-sandbox.nix's enable option before running this alongside anything else on this host.
  MODULES.services.n8n-sandbox.enable = true;

  # Second chat UI, alongside Open WebUI - see librechat.nix. (The mcp-switchboard hub that used
  # to feed both this and n8n's MCP nodes was removed entirely; see git history.)
  MODULES.services.librechat.enable = true;

  # Paseo control plane - see hosts/hp/RUNBOOK/RUNBOOK-paseo.md + modules/services/paseo.nix. The hub
  # daemon serves https://paseo.hp (tailnet), the relay is the one public piece (Funnel port
  # 10000), and https://hp.tail546fb.ts.net:8443/install/<token>/{opencode,pi}.sh bootstraps
  # remote harness machines. Secrets: sops paseo/*.
  MODULES.services.paseo.enable = true;
  # Hermes' own Paseo daemon (uid hermes, loopback 8116, dials out to the relay above): drives
  # Hermes conversations from the Paseo app/dashboard via the ACP provider "Hermes". Its egress
  # gets exactly one extra hermes-egress RETURN rule (tailnet IP:10000) - see paseo-hermes.nix.
  # Secret: sops paseo/hermes_daemon_password.
  MODULES.services.paseo-hermes.enable = true;

  # Personal agent stack - see RUNBOOK-hermes.md next to this file for the manual steps (sops
  # secrets, bridge logins, OAuth). A private Matrix server with federation off, reachable only
  # over the tailnet (https://matrix.hp, Element at https://element.hp); the mautrix bridges put
  # WhatsApp, Signal and Slack chats into it; Hermes talks to akos there and can read the bridged
  # rooms it is invited to.
  # One namespace for all Matrix bridges. whatsapp/signal/slack/discord are mautrix
  # appservices (see modules/services/mautrix.nix); Mattermost rides in via matterbridge
  # instead of a second appservice: relay style, one bot user, chats attached with `!mm
  # join` in the control room; its login-as-you credentials come from sops
  # (mattermost/password).
  MODULES.services.matrix = {
    enable = true;
    whatsapp.enable = true;
    signal.enable = true;
    slack.enable = true;
    discord.enable = true;
    matterbridge = {
      enable = true;
      mattermostUser = "AkosPapp";
      # mirror every public channel of both teams, not just the ones the account joined
      autojoinPublicTeams = [ "fsinf" "w-inf-tuwien" ];
    };
  };
  MODULES.services.hermes-agent.enable = true;

  # Hermes' calendar, out to the world: a token-gated ICS feed at
  # https://hp.tail546fb.ts.net:8443/ics/<token>/hermes.ics (the token lives in sops as
  # hermes/ics_token) - this is what goes into Google Calendar. It exists because Tailscale's own
  # `serve` cannot: any serve entry makes tailscaled bind 443 on the tailscale IP, which is
  # Traefik's listener, and Traefik then dies at its next restart (this took down every *.hp site
  # once already). The feed file itself is /var/lib/hermes/ics-serve/hermes.ics, rewritten by
  # Hermes' cron job. See hermes-ics.nix.
  MODULES.services.hermes-ics.enable = true;

  # Trilium Notes (https://triliumnotes.org) as the knowledge base - https://trilium.hp on the
  # tailnet. The ETAPI token was created in the UI and stored in sops (trilium/etapi_token), so
  # Hermes reads and writes notes through it (see trilium.nix).
  MODULES.services.trilium.enable = true;
  MODULES.services.trilium.etapiTokenSecret = "trilium/etapi_token";
  # Settings -> AI comes up with this host's LiteLLM as the provider, on the master-key-minted
  # virtual key trilium/litellm_api_key (trilium.nix's `litellm` options for the seeding
  # mechanics and the one-time key creation command).
  MODULES.services.trilium.litellm.enable = true;

  # Outline was tried and dropped - not needed. Its data (Postgres's "outline" database,
  # /var/lib/outline) was removed by hand on the host; see git history for how it was set up if
  # it comes back. mdbook (public docs) is unrelated and stays on.
  MODULES.services.outline.enable = false;

  # Public (Tailscale Funnel -> Traefik's `public` entry point) at https://hp.tail546fb.ts.net:8443/mdbook,
  # behind a git.robo4you.at login - see RUNBOOK-public.md. The docs follow the baumit-docs
  # package through a Forgejo webhook (same runbook).
  MODULES.services.mdbook = {
    enable = true;
    # Only the Owners team of the baumit org on git.robo4you.at.
    allowedGroups = ["baumit:owners"];
  };
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
    # lid closed = keep working, on battery AND external power AND docked
    # (HandleLidSwitch alone only covers the battery case; the other two keys
    # default to "lock" in systemd >= 256 and win when AC/dock is active)
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
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
