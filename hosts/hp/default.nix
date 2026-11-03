{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  MODULES.networking.tailscale.hostIP = "100.92.36.52";
  # hp runs unattended (no physical access path except tailscale): restart tailscaled
  # when it hangs offline (4 probes * 90 s), so a wedged session can't orphan it again.
  MODULES.networking.tailscale.watchdog.enable = true;
  # The fleet's TU Wien VPN gateway (modules/networking/tuvpn.nix): this box physically
  # sits in the lab, i.e. LAN-adjacent to the TU gateway, which is the one place a
  # TCP-datachannel AnyConnect session cannot collapse - legion5 running openconnect
  # itself from far away is the slow path the module header explains. On-demand: the
  # laptop's tuvpn-via-hp toggle ssh-starts tuvpn.service here, the tunnel advertises the
  # TU prefixes as tailnet subnet routes and MASQUERADEs the transit; hp's own traffic
  # never enters it (split profile, no default route). No akos uid here, so the secrets
  # mount root:root (same secretOwner pattern as the opencode module below).
  MODULES.networking.tuvpn = {
    server.enable = true;
    secretOwner = "root";
    secretGroup = "root";
  };
  # Nightly: pull litellm/omniroute/trilium images, recreate a container only when its
  # image actually changed (docker-images-update.nix).
  MODULES.virtualisation.docker-images-update.enable = true;

  # VPN-aware split DNS (modules/networking/dns/split-dns.nix): dnsmasq becomes the system
  # resolver, the tailnet/netbird forwards follow the VPNs' real state, and tailscaled stops
  # managing resolv.conf. hp is the fleet's exit node and accepts tailnet routes; the AirLab
  # forward is static here because the box physically sits in the lab.
  MODULES.networking.dns.splitDns = {
    enable = true;
    advertiseExitNode = true;
    labForward.enable = true;
  };
  networking.enableIPv6 = false;

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
      # 2755 setgid bit the hermes module's tmpfiles rules already give new files group=hermes
      # through kernel inheritance, which is all the agent's read access needs.
      extra_devices = ["phone"];
      # git stays on legion5; hp only wants the markdown. Ignore patterns are per-device, so this
      # doesn't change what legion5 and the phone exchange with each other.
      ignorePatterns = ["/.git"];
    }
  ];

  PROFILES.zroot.enable = true;
  PROFILES.server.enable = true;
  MODULES.security.sops.enable = true;
  # No X11 / ssh-agent auth on a server (2026-10-24 audit #8): nobody graphs onto hp, and a
  # forwarded agent is every key it holds. The laptop (legion5) keeps both.
  MODULES.networking.sshd.x11Forwarding = false;
  MODULES.networking.sshd.agentAuth = false;
  # MODULES.system.printing.enable = true;
  # services.printing.openFirewall = true;
  # services.printing.listenAddresses = [
  #   "127.0.0.1:${toString config.PORTS.cups}"
  #   "${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.cups}"
  # ];
  # services.printing.allowFrom = ["all"];
  # MODULES.networking.traefik.services.cups = "127.0.0.1:${toString config.PORTS.cups}";

  MODULES.networking.traefik.enable = true;
  # The public face on akosp.app: a Cloudflare Tunnel whose single wildcard ingress lands on
  # Traefik's loopback `cloudflare` entry point, plus a oneshot that keeps the zone's records
  # pointed at the tunnel through the Cloudflare API (a name appears in DNS exactly when it has
  # a route - matrix.nix is the first consumer, see the `public` options there). TLS is
  # Cloudflare's Universal SSL at their edge; no public port opens here, and unlike the Funnel
  # (RUNBOOK-public.md) this is the real domain, so clients like Matrix federation work.
  # Secrets and the one-time tunnel creation: RUNBOOK-cloudflare.md / `nix run .#cloudflare-config`.
  # Created 2026-10-24 with the setup app flow (tunnel `hp`, CNAMEs akosp.app + m.akosp.app
  # routed, credentials + cert.pem in sops).
  MODULES.networking.dns.cloudflare = {
    enable = true;
    domain = "akosp.app";
    tunnel.uuid = "c5955163-d4b6-4f01-9d60-bb33a57910b8";
  };
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
  # 21 GiB box; eval fails if the LIMITS table's MemoryHigh lines stop fitting (PLAN.md §1.2).
  # 19G since 2026-10-30, the day the paperless row landed and broke the old 18G sum: owner
  # measured the box idle at ~60% RAM with most of that ZFS ARC (reclaimable under pressure),
  # so the throttle-line cap - not the hardware - is the binding limit here, and it moved to
  # keep every row's memHigh honest instead of squeezing a new one below its working set.
  MODULES.system.limits.memoryBudget = "19G";
  # Author the §1.7 PSI-pressure alert rules here; Syncthing ships them to every Prometheus.
  MODULES.system.limits.managePressureRules = true;
  # PLAN.md §2 Tier A + §3.4: per-service containment specs live in modules/security/jail.nix
  # (fleet table, enable=false default); flipped on here only for units that exist on this
  # host with a resolvable jail user (phpfpm/trilium/omniroute run as root today - they need a
  # User= before they can ride the uid-based egress chains). Every deny is LOGged
  # "egress-deny-<jail>: " into journald -> Loki. Flip `backend = "microvm"` per row when §6
  # lands; the spec carries over unchanged.
  MODULES.security.jails.postgresql.enable = true;
  MODULES.security.jails.matrixSynapse.enable = true;
  MODULES.security.jails.matrixMas.enable = true;
  MODULES.security.jails.mautrix-whatsapp.enable = true;
  MODULES.security.jails.mautrix-signal.enable = true;
  MODULES.security.jails.mautrix-slack.enable = true;
  MODULES.security.jails.mautrix-discord.enable = true;
  MODULES.security.jails.mautrix-jabber.enable = true;
  MODULES.security.jails.homepage.enable = true;
  MODULES.security.jails.searx.enable = true;
  MODULES.security.jails.prometheus.enable = true;
  MODULES.security.jails.loki.enable = true;
  MODULES.security.jails.grafana.enable = true;
  MODULES.security.jails.syncthing.enable = true;
  MODULES.security.jails.firefly.enable = true;
  # PLAN §3: auditd + execve keys for the code-running class (hermes IS the agent uid -
  # paseo-hermes shares it; matrix-synapse's tree is static so execve is near-silent) + the
  # journald forwarder + Grafana paging rules. Container workloads run as root's uid and are
  # covered by their jails' egress LOGs, not execve keys.
  MODULES.security.audit.enable = true;
  # PLAN §4: znapzend L1 snapshots + the §4.2 fleet schedule; persist/hp replicates to
  # akos01 (L2) - daemon on the source, destination pruned as part of replication.
  MODULES.system.znapzend = {
    enable = true;
    sshKeySecret = "znapzend/ssh_key_b64";
    # lands on zroot/persist/hp/dump -> rides the recursive push to akos01
    pgDumpDir = "/var/lib/pgdump";
    # PLAN's manual `zfs create` before the first 00:05 timer became this idempotent
    # ExecStartPre instead (znapzend.nix): the logical dump lands ON the dataset, which is
    # what makes it ride the L2 push to akos01.
    pgDumpDataset = "zroot/persist/hp/dump";
    jobs = [
      {
        dataset = "zroot/root";
        plan = "1d=>1h,2w=>1d,8w=>1w";
      }
      {
        dataset = "zroot/persist/hp";
        plan = "1d=>1h,2w=>1d,8w=>1w";
        destinations.akos01 = {
          host = "root@akos01";
          dataset = "zroot/persist/hp";
        };
      }
      # The laptop replica this box receives: local snapshots only (§4.2 row 3).
      {
        dataset = "zroot/persist/legion5";
        plan = "1d=>1h,2w=>1d,8w=>1w";
      }
    ];
  };
  # PLAN §6: microVM host - prototype guest proves the pipeline before any jail flips
  # backend = "microvm" (jail.nix refuses the flip until the name is in this list).
  MODULES.system.microvmHost = {
    enable = true;
    vms = ["vm-agents"];
  };

  # PLAN §7: east-west service graph in observe mode (log-only) + the passive Suricata
  # tap (hp is the tailnet aggregation point - one tap is enough); flip
  # MODULES.security.serviceGraph.enforce after a week of explainable sg-seen logs
  # (query {unit="kernel"} |= "sg-seen" / {job=~".*suricata.*"} in Loki).
  MODULES.security.serviceGraph = {
    enable = true;
    suricata.enable = true;
    allow = [
      # step-ca issuance arrives over the tailnet from every enrollment (incl. VMs later).
      {
        name = "step-ca";
        ports = [config.PORTS.stepCa];
        from = ["100.64.0.0/10"];
      }
      # znapzend push target is ssh (covered); the laptop replica arrives over tailscale
      # too - nothing extra needed yet, this list is where host-local edges will land.
    ];
  };

  MODULES.security.audit.execUsers = [
    "postgres"
    "hermes"
    "paseo"
    "matrix-synapse"
  ];

  # Coroot: node-agent only on hp (2026-10-26: the server half - UI + ClickHouse - was
  # disabled here and aggregation moved to akos01, the fleet's single Coroot server).
  # The agent pushes over Tailscale to akos01's collector (derived serverHost), hp is
  # visualised in that server's UI (coroot.<akos01's domain>); the old per-host servers
  # (2026-10-25) left the hp-local data in the now-orphaned coroot-data and
  # coroot-clickhouse-data docker volumes. Loopback OTLP emitters (litellm, open-webui)
  # key off coroot.enable and switch their trace export off on this host by themselves.
  MODULES.services.coroot.agentEnable = true;
  # Coroot RCA -> Postgres metrics for this box's cluster (role+extensions provisioned by
  # postgresql.nix; credentials go into Coroot's per-app form once per monitored instance).
  MODULES.services.postgres.corootIntegration.enable = true;

  # n8n, the n8n-sandbox runner and LibreChat were removed from the fleet on 2026-10-24
  # (PLAN.md §1.5) - the chat UIs that remain are Open WebUI and Omniroute's own.

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

  # opencode (terminal coding agent) on this host, for root's shell. hp has no akos uid, so the
  # module cannot be reached via users/akos.nix and is enabled here directly, with the API-key
  # secret mounted root:root (secretOwner/secretGroup). What root gets is exactly the interactive
  # setup legion5's akos uses: the module's default provider catalogue and model come from
  # modules/services/model-catalog.nix, so only the model choice and the root ownership are
  # host facts here.
  MODULES.services.opencode = {
    enable = true;
    secretOwner = "root";
    secretGroup = "root";
    defaultModel = "litellm/futurelab/qwen3.8-flash-next";
    smallModel = "litellm/futurelab/qwen3.8-flash-next";
  };

  # Personal agent stack - see RUNBOOK-hermes.md next to this file for the manual steps (sops
  # secrets, bridge logins, OAuth). The mautrix bridges put WhatsApp, Signal and Slack chats into
  # it; Hermes talks to akos there and can read the bridged rooms it is invited to.
  # Identity is the public domain now: @akos:akosp.app, served at https://m.akosp.app through the
  # Cloudflare Tunnel with federation ON (matrix.nix's `public` options: the m. + apex routes and
  # the .well-known delegations), so other homeservers can reach it. https://matrix.hp stays up on
  # the tailnet for Element and the bridges. Account creation stays closed to everyone: open
  # registration is off, and the only accounts that exist are the ones matrix.nix provisions from
  # sops (akos, hermes). Element stays tailnet-only.
  # The matrix.hp -> akosp.app server_name migration ran as a rooms-wipe (accounts, Mattermost
  # logins, channel attachments and ghost registrations kept; old Matrix-side message copies,
  # which duplicate the networks' own history, were dropped - newer Synapse recomputes v11 event
  # IDs from the event JSON, so a rewritten history can never load). Runbook: RUNBOOK-cloudflare.md.
  MODULES.services.matrix.serverName = "akosp.app";
  MODULES.services.matrix.public.enable = true;
  # One namespace for all Matrix bridges. whatsapp/signal/slack/discord are mautrix
  # appservices (see modules/services/mautrix.nix); Mattermost rides in via matterbridge
  # instead of a second appservice: relay style, one bot user, chats attached with `!mm
  # join` in the control room; its login-as-you credentials come from sops
  # (mattermost/password).
  MODULES.services.matrix = {
    enable = true;
    # MAS delegation: browser/QR logins, per-device tokens, passwordless for humans. Legacy
    # clients (bridges, Hermes) keep working through the compat splitter. Costs double-puppeting
    # and bridge-side E2EE (appservice login is rejected by MAS) - see matrix.nix's mas option.
    mas.enable = true;
    whatsapp.enable = true;
    signal.enable = true;
    slack.enable = true;
    discord.enable = true;
    # XMPP puppeting bridge (jmpchat-matrix-bridge) against the local Prosody below - the one
    # bridge here with Matrix-side E2EE on. Login: DM @jabberbot:akosp.app, "!jabber login".
    jabber.enable = true;
    mattermost = {
      # puppeting bridge: messages appear from the real Mattermost users, and sends appear as me
      # OFF for now: too many bridged channels made Element lag (2026-10-24). Flip back on after
      # the MAS reset once the client can keep up.
      enable = false;
      user = "AkosPapp";
      teams = ["fsinf" "w-inf-tuwien"];
    };
    matterbridge = {
      # relay-style predecessor, replaced by mautrix-mattermost (everything came from one
      # account). Its rooms stay in the database as orphans until pruned by hand; re-enabling
      # this one also requires disabling mattermost above (they would double-relay).
      enable = false;
    };
  };

  # Prosody XMPP server hosting akosp.app (same domain as Matrix; JIDs like akos@akosp.app).
  # Reachability is IPv6-only (hp's IPv4 is NATed): the xmpp module maintains the AAAA at
  # xmpp.akosp.app plus the _xmpp-client/_xmpp-server SRV records through the Cloudflare API
  # token (cloudflare/dns_api_token) and a DNS-01 cert from Let's Encrypt. Accounts come from
  # sops (xmpp/*_password), hashed into Prosody once at first boot. Matrix side: the jabber
  # bridge above. Runbook: RUNBOOK-xmpp.md.
  MODULES.services.xmpp.enable = true;

  MODULES.services.hermes-agent = {
    enable = true;
    # Bind the Syncthing notes share (the MODULES.services.syncthing.shares entry above) into
    # the agent's sandbox at <stateDir>/notes, with the tmpfiles modes and the hermes-notes-edit
    # escalation tool (hermes-agent.nix). hp's syncthing runs as `syncthing` - the default.
    notes.enable = true;
  };

  # Hermes' calendar, out to the world: a token-gated ICS feed at
  # https://hp.tail546fb.ts.net:8443/ics/<token>/hermes.ics (the token lives in sops as
  # hermes/ics_token) - this is what goes into Google Calendar. It exists because Tailscale's own
  # `serve` cannot: any serve entry makes tailscaled bind 443 on the tailscale IP, which is
  # Traefik's listener, and Traefik then dies at its next restart (this took down every *.hp site
  # once already). The feed file itself is /var/lib/hermes/ics-serve/hermes.ics, rewritten by
  # Hermes' cron job. See hermes-ics.nix.
  MODULES.services.hermes-ics.enable = true;

  # Trilium Notes - RETIRED 2026-11-11. The live notes system is Joplin now: the sync tree
  # /var/lib/hermes/joplin (SFTPGo WebDAV target) is what Hermes' cron writes through
  # joplin_event_sync.py and what the ICS feed links into (joplin:// deep links). The Trilium
  # archive on disk (/var/lib/trilium container volume) is untouched and still readable by
  # re-enabling - see git history and the trilium-etapi skill for the ETAPI recipes.
  MODULES.services.trilium.enable = false;
  MODULES.services.trilium.etapiTokenSecret = "trilium/etapi_token";
  # Settings -> AI comes up with this host's LiteLLM as the provider, on the master-key-minted
  # virtual key trilium/litellm_api_key (trilium.nix's `litellm` options for the seeding
  # mechanics and the one-time key creation command).
  MODULES.services.trilium.litellm.enable = false;

  # Joplin (https://joplinapp.org), side by side with Trilium for the same job - https://joplin.hp
  # on the tailnet: the Joplin DESKTOP streamed from lscr.io/linuxserver/joplin. The Hermes
  # comparison is API vs FILES: Trilium goes through ETAPI (above), while Joplin syncs its notes
  # as plain markdown into /var/lib/hermes/joplin, which Hermes reads and writes directly - the
  # container writes with the hermes uid, so both sides own every file (joplin.nix). First-boot
  # steps are in the syncDir option's text: sync target "File system", path /joplin-sync,
  # auto-sync on. No browser login (webUser = null, 2026-10-27: every tailnet peer is akos' own
  # device, so the nginx basic auth guards nothing a determined-enough local isn't already
  # trusted with; see the option's caveat about Joplin plugins before widening the tail).
  # AI chat is not seeded the way Trilium's LiteLLM provider is - if wanted, Options -> AI with
  # http://127.0.0.1:8095/v1 and a virtual key minted like trilium.nix describes.
  MODULES.services.joplin = {
    enable = true;
    webUser = null;
    # The W6400 (amdgpu, renderD128) moves Selkies' capture/encode off the CPU - measured
    # 2026-10-27: software x264 readback under the cgroup quota felt laggy from the browser,
    # the image's own README calls this flag the whole GPU setup on AMD.
    driDevice = "/dev/dri";
  };

  # paperless-ngx (https://paperless-ngx.com), the document archive - https://paperless.hp on
  # the tailnet. The third note-app sibling on this box (trilium.nix API, joplin.nix files) and
  # it joins the API camp: Hermes talks REST, not files - two loopback containers (app on
  # sqlite + a valkey broker, the v3 image has no bundled halves) behind Traefik (paperless.nix).
  # Hermes' token is the same one-time story trilium's ETAPI was: create the superuser on the
  # first-run page, mint the token per paperless.nix's apiTokenSecret text, store it in sops as
  # paperless/api_token, then flip the line below - until then the archive runs, but only the
  # human UI can touch it. OCR languages ride hermes' eng+deu default.
  MODULES.services.paperless.enable = true;
  # MODULES.services.paperless.apiTokenSecret = "paperless/api_token";

  # Outline was tried and dropped - not needed. Its data (Postgres's "outline" database,
  # /var/lib/outline) was removed by hand on the host; see git history for how it was set up if
  # it comes back. mdbook (public docs) is unrelated and stays on.
  MODULES.services.outline.enable = false;

  # Public (Tailscale Funnel -> Traefik's `funnel` entry point) at https://hp.tail546fb.ts.net:8443/mdbook,
  # behind a git.robo4you.at login - see RUNBOOK-public.md. The docs follow the baumit-docs
  # package through a Forgejo webhook (same runbook).
  MODULES.services.mdbook = {
    enable = true;
    # Only the Owners team of the baumit org on git.robo4you.at.
    allowedGroups = ["baumit:owners"];
  };
  # Client ID and secret come from sops (idp/client_id, idp/client_secret).
  MODULES.security.idp.enable = true;

  # WebDAV for Joplin's sync target, served by the EXISTING sftpgo users (accounts are managed
  # in the WebAdmin UI at https://sftpgo.hp, never declaratively - see sftpgo.nix). One-time
  # step NOW ACTUALLY PRESENT on hp (2026-10-29, later than this block's first wording claimed):
  # user akos virtual folder joplin, virtual path /joplin, mapped path /var/lib/hermes/joplin.
  # It was created by a stopped-daemon sqlite insert, not the WebAdmin click, because the click
  # never happened the first time and devices were silently syncing an empty wrong tree: with
  # no /joplin virtual folder, the URL resolved INSIDE akos's home and Joplin's first attempt
  # auto-created /var/lib/sftpgo/files/joplin as a real 12-item sync tree - clients then kept
  # syncing THAT (216 "successful" requests today while the export sat invisible in the real
  # tree; Joplin #12810 makes an unreachable/wrong target look like success). Daemon user-cache
  # ExpirationTime is 0 (infinite), so DB edits require a daemon restart - the insert shape
  # (folders row with the local filesystem JSON, users_folders_mapping quotas 0/0, "/" perms
  # covering the vfolder) was replicated from an API-calibrated row on the same sftpgo 2.7.5.
  # The stray dir is kept renamed as files/joplin-stray-20261029; its 11 device-side items were
  # copied into the real tree first (ids are add-only) so no client tombstones notes it
  # believes already synced. A second account `joplin` (home = the real tree, also never
  # clicked into the UI plan) exists DISABLED in the DB - delete via WebAdmin when convenient;
  # accounts stay WebAdmin-managed per sftpgo.nix. Clients (phone, legion5
  # desktop) then sync to https://webdav.hp/joplin with the akos credentials they already use
  # for Zotero at https://webdav.hp/zotero - same user, same password, different folder. The
  # streamed desktop on https://joplin.hp KEEPS its "File system" sync (Hermes' file bridge,
  # joplin.nix): WebDAV "/" + virtual paths resolve inside the akos account, and /joplin maps
  # to the very same directory the container syncs locally, so every client shares one tree,
  # last-write-wins. runAsUser = hermes is what makes that safe: the container writes its sync
  # files 0600 as the hermes uid and /var/lib/hermes is 2770 - measured 2026-10-29 that a
  # stock sftpgo-uid daemon could neither read them nor traverse the state dir. Zotero's
  # storage and the sqlite DB are chowned to hermes along with them (idempotent ExecStartPre
  # in sftpgo.nix) - paths and credentials unchanged, so zotero keeps working.
  MODULES.services.sftpgo = {
    enable = true;
    runAsUser = "hermes";
    sharedPaths = ["/var/lib/hermes/joplin"];
  };
  MODULES.services.i2pd.enable = false;
  MODULES.services.immich.machineLearning.enable = true;
  # The immich SERVER moved to akos01, but the pre-migration immich database stayed
  # on this box's shared postgres, and the L3 dumpall (MODULES.system.znapzend's
  # pgDumpDir) reads every database on this cluster. That DB carries a REGISTERED
  # vchord extension (immich 3.x created it while the server was still here), so on
  # a bare package pg_dumpall dies at pg_get_indexdef on every vchord index:
  # 'could not access file "vchord"'. Re-added exactly what the nixpkgs immich module
  # shipped while services.immich.database.enable was still set here - same package
  # version, same preload. Retire together with the leftover DB itself.
  services.postgresql.extensions = ps: [
    ps.pgvector
    ps.vectorchord
  ];
  MODULES.services.postgres.preloadLibraries = ["vchord.so"];
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
  MODULES.nix.builders.airlab = true;
}
