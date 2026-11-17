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
    # The lab's robot net 10.210.0.0/24 (r4uai00, r4uai01) rides hp's own lab routing to the
    # AirLab gateway, so advertise it to the tailnet PERMANENTLY (reconcile timer), not just
    # while the TU tunnel lives: tailnet devices without a NetBird client (the phone) reach
    # the robots through this box. Verified 2026-11-10: hp TCP-connects 10.210.0.10/.50:22
    # via its 10.50/23 legs. NetBird clients keep using NetBird's own 100.124.0.0/16 routes;
    # transit SYNs on tailscale0 may log SG-DRIFT on hp's tap like the TU transit does
    # (log-only today, same caveat as MODULES.networking.tuvpn.server.enable).
    server.lanTransit = {
      enable = true;
      prefixes = ["10.210.0.0/24"];
    };
    # 2026-11-10: hp is the tailnet's standing VPN proxy (phone/any tailnet device reaches
    # r4uai*, akos01 services and datalab without a per-device VPN app), so the tunnel
    # lives 24/7 and the TU prefixes ride advertised from boot, not just while someone
    # toggles. The module's on-demand default stays for hosts that want it; the toggle
    # still owns the CLIENT side (accept-routes here) and survives this always-on choice
    # (start on a running unit is a no-op; status reads the kernel routes, not the unit).
    server.startAtBoot = true;
  };
  # Public SSH host keys (safe to commit), keyed by the tailnet IP peers dial. Cross-checked
  # 2026-11-03: keyscan over tailscale0 == the `hp` entries in akos's known_hosts, i.e.
  # verified identity, not a blind TOFU grab. Legion5's tuvpn toggle pins these in
  # /etc/tuvpn/ssh-known-hosts, and every fleet host's herdr catalog now pins them too
  # (/etc/herdr/known-hosts) - a host-key rotation that skips this list means the tunnel
  # toggle and all hub connections fail closed with a clear error, never silently.
  # Regenerate with `ssh-keyscan 100.92.36.52` if /etc/ssh/ssh_host_* ever change.
  # (Moved 2026-11-09 from MODULES.networking.tuvpn.server.hostKeys to the fleet's
  # single-owner table, modules/networking/ssh-client.nix - the herdr module reads the
  # same fact and must not depend on tuvpn.)
  MODULES.networking.sshClient.hostKeys = [
    "100.92.36.52 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHoBUmI+TbSwChT7XI8JAHTiHrELZTuSiNKrAnELMhT"
    "100.92.36.52 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDD0c6to6DpnSsrVvYihDzwDKarnQ5wvJkq+OrVTr6eVFGtU8N8QrDgO4+UcB990rYA19E0Kjsg7gjhutWj/2Y5zGPxW+t2rTm99jDPXfa/8iP9gUHNM8pQh7EQwV3UkIKkvJVzckBrzdUTPXwBNBAASyK2kB4yDcKl7T9XVJnLyW5911dyMIAJ8SFYbtAciFtsrsfJM2iNK0FLy7fi8c/Z9rVoAgWvu4jrG49i3vZEe7DGBQ7D+gRjGKab//FfUtOEpG8yWvMij0w36DkEarTEujWTX5GZPqN4edOkoxO93wR3Dp6UFpYxFFRPk5RhN7rZGLdF5Rm8drRfBk0hBkdQuL15RY7C+spdNDkSpHFIx3VKuB5VInj/KBdsU0CzjRx9jX5z8CX6h/7+n0SP3UeN0sE+ap3BLDtSpIL3mBmKMq2umo4CcZRfgqAHp/ivJ3IyKg7iDDdJOn+KMTR124tFNUy5n5Algh2wR0n6m33xWHbbNnIuAPbqORjtzXyPhhDE8zJioUV1bXvdBCtDiYfIJ4Dzgh7C9aVLubYXxYTbqmBoNs7sCZ2qCto/f+UxcBoK8hrd1EPYe34ACyl0P12WyrJvH9E9aQ22wqsWA6Xvc9+fBpXJyYCadQYShLXPXcx750f748JTp9++K7vKEEEMxCUh74rINBEOTYBUWP4tUw=="
  ];
  # Nightly: pull omniroute/trilium images, recreate a container only when its
  # image actually changed (docker-images-update.nix).
  MODULES.virtualisation.docker-images-update.enable = true;
  # herdr (herdr.dev): binaries only, no desktop app. hp has no normal user account (the
  # akos module is opt-in and off here), so there is nothing to launch a GUI at - but the
  # hermes service account DOES get laid out per-user state (2026-11-10, users.hermes
  # below). What hp still needs is hc on
  # PATH in the non-login shell SSH gives an incoming client - that is what makes this box
  # an `hc machine add hp` / `herdr --remote hp` target whose agents keep running after the
  # SSH session ends, and hc is the whole reason to want herdr on a box you never sit at.
  # installApp stays false: the GUI needs a display server and pulls the vulkan/mesa set
  # into a headless host's closure for no benefit. The three install* options default to
  # "whatever the nixpkgs-unstable pin carries", so once the pin moves past
  # 1c89083e451e the herdr-core package this host is missing appears here by itself - no
  # second edit.
  #
  # hp is also the fleet's herdr HUB (2026-11-09): the phone (Termius over the
  # tailnet) connects to hp's sshd - the one host with a public tailnet name, the tailscale
  # watchdog and static reachability - and hp's TUI machine catalog (auto-derived by
  # modules/services/herdr.nix from every host enabling the module) shows legion5/akos01 in
  # ONE sidebar. users.root + linger: root's user manager is what keeps /run/user/0 - and
  # with it the transient units herdr's remote bootstrap uses - alive between logins; the
  # TUI server itself lives in ~/.config/herdr/herdr.sock (a tmpfs-independent path,
  # verified against v0.9.x session.rs) and hp is the single most-rebooted-to-service box of
  # the three, so root's first `herdr` attach starts it. sshKeySecret: the pinned hub key
  # (sops) makes the hub->machine hop work with NO agent and NO forwarded creds - measured
  # 2026-11-09: without forwarding, root@hp cannot auth to the fleet at all (its only key
  # is the nix-builder one, untrusted here), so the hub identity is load-bearing, and its
  # public half lives in profiles/global.nix root authorizedKeys on every host.
  MODULES.services.herdr = {
    enable = true;
    installApp = false;
    sshKeySecret = "herdr/hub_ssh_key";
    coreRegistry.user = "root";
    users.root = {
      enable = true;
      cli.enable = true;
    };
    # Legion5's agents live in akos's TUI (the laptop's MODULES.services.herdr.users.akos
    # block), not root's - so the hub dials the laptop AS AKOS. users/akos.nix carries the
    # hub's public key for exactly this hop. hp/akos01 stay root (no other account there).
    machines.legion5.user = "akos";
    # The agent's OWN terminal, 2026-11-10: the hermes account gets a herdr TUI
    # server + catalog row next to root's, so the phone (and the laptop, whose key
    # also trusts the account) reach the agent in a hub-dialed session. cli.service
    # because the account must never linger (hermes-agent.nix: a user manager would
    # move the gateway's cron workers out of the sandbox) and the hub's own remote
    # bootstrap spawns no server for a linger-less account (measured same day) -
    # the fleet unit starts it and every client just attaches; the unit's PATH/TERM
    # env (see herdr.nix) is what puts `hermes` in the panes.
    users.hermes = {
      enable = true;
      cli = {
        enable = true;
        service = true;
      };
    };
    # hp's OWN row (the derived catalog always excludes self): the alias
    # herdr-hp-hermes + User hermes, pinned to hp's own host keys and dialed with
    # the hub key by the root-uid Match - a different profile id from root's
    # "hp", which is the point. Flows to legion5/akos01 verbatim via
    # coreRegistry, so every host's catalog agrees.
    machines.hp-hermes = {
      hostname = config.MODULES.networking.tailscale.hostIP;
      user = "hermes";
      knownHosts = config.MODULES.networking.sshClient.hostKeys;
    };
    # The datalab terminal, 2026-11-11: the same self-dial trick for the harness
    # account (modules/services/datalab-harness.nix terminalAccess - linger-less, so
    # cli.service again). Every pane of this server IS an `ssh -t datalab` (the
    # account's login shell is the pinned ssh wrapper), so the phone gets a "datalab
    # machine" whose terminals hold the TU keepalive and die with it - herdr never
    # learns anything crossed a network. Trust set = the same three keys as hermes
    # below; phone route: datalab@hp AND datalab@datalab.hp (dns.aliases further
    # down - the phone's ssh client keys machines by hostname and cannot add hp twice).
    users.datalab = {
      enable = true;
      cli = {
        enable = true;
        service = true;
      };
    };
    machines.hp-datalab = {
      hostname = config.MODULES.networking.tailscale.hostIP;
      user = "datalab";
      knownHosts = config.MODULES.networking.sshClient.hostKeys;
    };
    # The lab robots, 2026-11-11: the phone's second route to the fleet (the herdr-native
    # one - the app talks ONLY to hp, hp dials the robots with the hub key, which is already
    # in apapp's authorized_keys on both boxes; measured: no secret key ever leaves hp's sops
    # mount). Lab IPs churn behind DHCP, but the HostKeyAlias pins (re-keyed to the herdr-*
    # alias at render) absorb that exactly like the laptop's ~/.ssh/config does. Host keys
    # are the laptop's TOFU'd pins, cross-checked against a fresh keyscan 2026-11-11 (both
    # ed25519 lines match). Off-flake hosts: hostname + user + knownHosts are the minimum.
    # Direct phone logins (Termius): users/herdr-mobile.pub was appended to
    # apapp@r4uai00:~/.ssh/authorized_keys 2026-11-11 by hand (same key hp/akos01 trust);
    # r4uai01 already carried it (mtime 10:32). The robots are Ubuntu, outside this flake -
    # THIS comment is the registry for that line; revocation = delete it there.
    machines.r4uai00 = {
      hostname = "10.210.0.10";
      user = "apapp";
      knownHosts = [
        "r4uai00 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHaTaGV9iR5N1uZNDtGQ52tC8/YUS9uAjfATPY9ccD+U"
      ];
    };
    machines.r4uai01 = {
      hostname = "10.210.0.50";
      user = "apapp";
      knownHosts = [
        "r4uai01 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHK6sRVfSpV3k8XGKlapnhyhqmBZTYZ6Tds8JJJicjOx"
      ];
    };
  };
  # Phone's core mobile SSH key; shared public material, no private key on hosts.
  users.users.root.openssh.authorizedKeys.keys = [
    (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-mobile.pub))
  ];

  # Terminal access to the Hermes agent (modules/services/hermes-agent.nix sshAccess),
  # 2026-11-10: the agent's interactive TUI must run AS THE HERMES UID - upstream's
  # gateway attach authenticates the control socket by SO_PEERCRED (hermes_cli/
  # gateway_runtime_discovery.py connect_private: a peer uid mismatch is
  # 'unsafe_control_peer'), so a root CLI can never join the gateway that chats over
  # Matrix and runs the crons; 2026-11-10 measured: `hermes gateway attach` as hermes
  # returns state:"ready" + a ws ticket against the live gateway, and as root there is
  # not even a hermes on PATH. The trust set is deliberately the SAME keys hp's root
  # carries (laptop + hub + phone - one human owns all three; shared files under
  # users/), so `ssh hermes@hp`, mosh, and the hub's self-dial (machines.hp-hermes
  # above) all work with NO new key material, and revocation stays "delete the line,
  # redeploy". The herdr account wiring lives in the MODULES.services.herdr block
  # above (users.hermes + machines.hp-hermes).
  MODULES.services.hermes-agent.sshAccess = {
    enable = true;
    authorizedKeys = [
      (lib.removeSuffix "\n" (builtins.readFile ../../users/akos-laptop.pub))
      (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-hub.pub))
      (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-mobile.pub))
    ];
  };

  # VPN-aware split DNS (modules/networking/dns/split-dns.nix): dnsmasq becomes the system
  # resolver, the tailnet/netbird forwards follow the VPNs' real state, and tailscaled stops
  # managing resolv.conf. hp is the fleet's exit node and accepts tailnet routes; the AirLab
  # forward is static here because the box physically sits in the lab.
  MODULES.networking.dns.splitDns = {
    enable = true;
    advertiseExitNode = true;
    labForward.enable = true;
    # NetBird enrolled 2026-11-11, but its zone forward stays off HERE: the lab DNS it
    # points at (100.124.160.88) is not authoritative for robo4you.at, so dnsmasq's RD=0
    # forwarding breaks CNAME chains leaving the lab's zone - measured same day:
    # stiftlerapi.robo4you.at answers the CNAME (airlab.robo4you.at) but no A via dnsmasq,
    # while RD=1 dig direct to the same server returns the full chain. Every robo4you.at
    # names hp consumes resolves identically on public DNS (idp 195.202.147.93, stiftlerapi
    # 185.199.x GitHub Pages), and wt0 DATA reachability is untouched by this flag.
    # Re-enable if the lab ever serves private-view names hp needs over NetBird.
    netbird.enable = false;
    # ...but the lab's `futurelab` zone IS private-view (r4uai00/r4uai01.futurelab exist only
    # on 100.124.160.88, measured 2026-11-11) and the phone resolves it THROUGH here: the
    # tailnet console maps the zone to this box's dnsmasq (split DNS), dnsmasq forwards over
    # wt0 while the netbird probe answers. Same mechanism as the old robo4you.at forward,
    # minus that zone's broken CNAME chain.
    netbird.extraZones = ["futurelab"];
    # Bare names for the phone (Termius has no zone suffix): MagicDNS probes `r4uai00.` and
    # `r4uai00.<search>` at the split resolver, and `datalab` has no zone at all (it's TU's
    # public cluster host, reachable via the approved TU subnet route). IPs measured against
    # the lab DNS + public DNS 2026-11-11; the robots' lab DHCP is static (10.210.0.x).
    tailnetRecords = {
      r4uai00 = "10.210.0.10";
      r4uai01 = "10.210.0.50";
      datalab = "128.130.194.213";
    };
  };
  # FutureLab subnet access; enrollment stays runtime state, DNS stays dnsmasq.
  MODULES.networking.netbird.enable = true;
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
  # 2026-11-11 user request: hardened kernel on the ZFS servers. nixpkgs 26.05 removed
  # linuxPackages_hardened ("lack of maintenance"), so modules/system/hardened-kernel.nix
  # rebuilds the pinned 6.18.59 with the grafix linux-hardened patchset (v6.18.59-hardened1)
  # + the vendored hardened defconfig, keeping the eBPF/kprobe floor coroot/docker/tailscale
  # need. Takes effect on the NEXT boot; the current generation stays selectable.
  # 2026-11-12: owner chose hardened 6.18.60 while all flake dependencies
  # update independently. The source and patch are pinned together in the module.
  # Activation installs a boot generation; it does not reboot this host.
  MODULES.system.hardenedKernel.enable = true;
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
  # a request still answers - slowly, on four Zen+ cores - while the laptop is shut. OmniRoute
  # seeds the two hosts as separate Ollama connections (same ids, different connection), so which
  # one a client gets is the client's pick; the replica-weighting litellm.nix did died with it
  # (phase 3, 2026-11-09).
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
  # https://omniroute.hp that goes in a client config. Providers, combos and API keys are
  # dashboard state; the nix-seeded connections (openrouter, futurelab) and the first-login
  # password in /var/lib/omniroute/secrets.env (INITIAL_PASSWORD) are omniroute.nix's - see
  # that file's header for the full seed list and the phase-3 history (litellm.nix deleted
  # 2026-11-09, its upstreams - openrouter/futurelab/openai/codex - already OmniRoute
  # connections, so nothing here restates them).
  MODULES.services.omniroute.enable = true;
  # The gateway itself, on the internet: https://hp.tail546fb.ts.net:8443/omniroute/v1 through
  # the shared Funnel origin (see RUNBOOK-public.md). It exists for the Paseo installers and
  # Amp's cloud - machines/clients with no Tailscale, for whom https://omniroute.hp is not an
  # address - and for any other off-tailnet client. Only the OpenAI-compatible prefix gets a
  # route: the admin UI and its management API stay tailnet-only, and what is public answers
  # only to an OmniRoute inference key (a per-service nix-minted key, or one minted on the
  # dashboard). Took over litellm's public.enable role at phase 3 (2026-11-09).
  MODULES.services.omniroute.public.enable = true;
  # audit #7 (2026-11-14): per-service minted inference keys (omniroute.nix header documents
  # the doctrine + the /api/keys API; the seed unit mints them at switch into
  # /var/lib/omniroute/keys, root-only, znapzend'd with the gateway dataset; a wiped DB or
  # file dir re-mints and logs "*** KEY VALUE CHANGED ***" - restart the consumer). The
  # shared omniroute_api_key in sops now serves ONLY the off-gateway-host harnesses.
  # One entry per CONSUMER THAT RUNS HERE: trilium (gateway disabled) gets its key when
  # it returns - keys.trilium should then be scoped (models = the one route it needs) so
  # a re-enabled note-db leak costs one model, plus gateway.apiTokenFile = the raw
  # filePath (and a cleared document.db llmProviders row so the seed-once re-seeds).
  # No ompBootstrap row (owner ruling 2026-11-15): the installer has no baked key -
  # every box mints its own omp-<hostname> credential, and the install DIES when the
  # mint endpoint is unreachable (a box that can't mint can't reach the gateway
  # either, so a shared fallback key would only ever install a harness that 401s).
  MODULES.services.omniroute.keys = {
    hermes = {}; # OMNIROUTE_API_KEY default fits the fork's .env line
    homepage.envVar = "HOMEPAGE_VAR_OMNIROUTE_API_KEY"; # homepage substitutes its unit env
    openWebui.envVar = "OPENAI_API_KEY"; # open-webui's EnvironmentFile variable
  };
  MODULES.services.hermes-agent.apiKeyFile =
    config.MODULES.services.omniroute.keys.hermes.envFilePath;
  MODULES.services.homepage.omnirouteKeyFile =
    config.MODULES.services.omniroute.keys.homepage.envFilePath;
  MODULES.services.open-webui.apiKeyFile =
    config.MODULES.services.omniroute.keys.openWebui.envFilePath;
  # The omp bootstrap installer, served token-gated at /install/<token>/omp.sh by
  # modules/services/bootstrap-installers.nix (the standalone successor of the retired
  # cockpit's endpoint). hp runs no omp itself - this only ships the fleet's omp config
  # to off-nix Linux/macOS boxes. No baked provider key at all: the installer mints this
  # box's own `omp-<hostname>` gateway credential at the hub's mint endpoint and DIES if
  # the mint fails (owner ruling 2026-11-15 - unreachable mint = unreachable gateway,
  # so a shared fallback key could only ever install a harness that 401s). See
  # modules/services/omp.nix's bootstrap block for what the script writes and what it
  # deliberately deviates from.
  MODULES.services.omp.bootstrap.enable = true;
  # The owner's short URL (2026-11-14): `curl https://hp/install-omp.sh | sh` on the
  # tailnet (the step-ca cert covers the apex, the bootstrap-installers apex router
  # answers Host(hp)), and the homepage tile points at the /omp page below, which
  # prints both this one-liner and the funnel URL with the enrollment token. The
  # script carries NO credential of its own (owner ruling 2026-11-15): a tailnet
  # stranger who curls it can only make the hub MINT a per-device key for their own
  # box (rate-capped per IP + name by the mint daemon), never read anyone else's.
  MODULES.services.bootstrapInstallers.scripts.omp.publicPath = "/install-omp.sh";
  # The public funnel face of the same script, token in a HEADER instead of the URL
  # (owner ask 2026-11-15): `curl -H "X-Install-Token: <token>"
  # https://hp.tail546fb.ts.net:8443/install/omp.sh | sh`. The token never rides a
  # URL anyone logs; the ACL is the rendered nginx include the render unit maintains.
  MODULES.services.bootstrapInstallers.headerTokens.omp = "/install-omp.sh";
  # Per-DEVICE keys for the copied one-liner (owner design 2026-11-15): the script,
  # run on ANY device (no Tailscale needed), mints its own gateway key named after
  # the box (`omp-<hostname>`, dashboard-revocable per device) through the loopback
  # installer-mint daemon - fetched via this header-gated /install/mint proxy, with
  # its OWN token (a leaked script copy mints keys; it cannot fetch other consumers'
  # scripts, and the daemon caps per-name + per-IP). The proxies.mint gate entry is
  # self-registered by MODULES.services.installerMint; this just supplies its token.
  MODULES.services.installerMint.enable = true;
  MODULES.services.bootstrapInstallers.apiKeys.INSTALL_MINT_TOKEN = "installer/mint_token";
  MODULES.services.omp.bootstrap.mintUrl =
    config.MODULES.networking.traefik.funnel.urlOf "/install/mint";
  # The fleet web-search MCP server (modules/services/mcp-perplexity.nix): every
  # device that ran the installer gets a perplexity entry in its mcp.json pointing at
  # the funnel /install/mcp gate; searches flow through the gateway's sonar-pro route
  # with a nix-minted key. Both halves self-register on enable (proxies.mcp gate +
  # the installer's $MCP_PERPLEXITY_TOKEN) - the mcpPerplexity key row below is the
  # only extra declaration needed.
  MODULES.services.mcpPerplexity.enable = true;
  MODULES.services.omniroute.keys.mcpPerplexity = {};
  # The homepage tile the owner asked for: opens the /omp page (next block), which
  # carries both one-liners. Icon is the project's OWN pi-symbol svg served from its
  # repo (the i2pd precedent - a remote logo URL). NOT the maintainer's GitHub avatar:
  # that is a person's face on a service tile (owner: "a random guy", 2026-11-15).
  MODULES.services.homepage.services.install-omp = {
    href = "https://${config.MODULES.networking.traefik.domain}/omp";
    icon = "https://raw.githubusercontent.com/can1357/oh-my-pi/main/assets/icon.svg";
    description = "curl|sh installer for omp";
  };
  MODULES.services.bootstrapInstallers.pages.omp = {
    path = "/omp";
    source = pkgs.writeText "omp-page.html" ''
          <!doctype html>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Install omp</title>
          <style>
            body { font: 15px/1.6 system-ui, sans-serif; max-width: 44rem; margin: 3rem auto; padding: 0 1rem;
                   background: #101418; color: #d8dee6; }
            h1 { font-size: 1.3rem; }
            p.lead { color: #8b97a8; }
            pre { background: #1a2027; border: 1px solid #2a3340; border-radius: 8px;
                  padding: .7rem .9rem; overflow-x: auto; white-space: pre-wrap; }
            code { color: #9ecbff; }
            small { color: #6b7686; }
          </style>
          <h1>omp - the fleet coding agent</h1>
          <p class="lead">Installs the pinned omp CLI and the fleet gateway config (the
          public OmniRoute funnel). Runs on <strong>any Linux/macOS box, with or without
          Tailscale, with or without curl</strong> (it self-fetches the binary via python3
          when curl is missing), mints <strong>its own gateway API key named after the
          machine</strong> (<code>omp-&lt;hostname&gt;</code>, revocable per device on the
          OmniRoute dashboard), and wires <strong>live web search</strong> (a self-hosted,
          free search MCP server behind the same funnel). Refuses NixOS hosts (declare
          <code>MODULES.services.omp</code> there instead).</p>
          <p>Copy-paste, works anywhere (the token rides a HEADER, never a URL anyone logs):</p>
          <pre>curl -fsSL -H "X-Install-Token: $BOOTSTRAP_INSTALL_TOKEN" \
      https://hp.tail546fb.ts.net:8443/install/omp.sh | sh</pre>
          <p>On the tailnet, the same install without the header:</p>
          <pre>curl https://hp/install-omp.sh | sh</pre>
          <p>From a fleet box that can ssh the target (installs it there, same per-device
          key mint):</p>
          <pre>omp-deploy [-J root@hp] user@host</pre>
          <small>Generated by the fleet hub (modules/services/bootstrap-installers.nix);
          re-rendered at every activation and secret rotation. This box mints its own
          gateway key (<code>omp-&lt;hostname&gt;</code>) at install time; if the hub's
          mint endpoint is unreachable the install aborts (no shared fallback key).</small>
    '';
  };
  MODULES.services.prometheus.enable = true;
  # 21 GiB box; eval fails if the LIMITS table's MemoryHigh lines stop fitting (PLAN.md §1.2).
  # 19G since 2026-10-30, the day the paperless row landed and broke the old 18G sum: owner
  # measured the box idle at ~60% RAM with most of that ZFS ARC (reclaimable under pressure),
  # so the throttle-line cap - not the hardware - is the binding limit here, and it moved to
  # keep every row's memHigh honest instead of squeezing a new one below its working set.
  # 2026-11-11: 19G -> 23G with the tiny/boring tier raises (below-the-working-set
  # throttles were causing real stalls - see the tier comments in limits.nix) and the
  # immich-server bump. Sum of memHigh overcomitting the 21G box is now the deliberate
  # owner call: the fleet's services don't all peak at once, MemoryHigh only throttles
  # (each row's memMax is still the hard wall), and hp has no swap so the wall is the
  # real boundary anyway. Old note: sized so the gateway + immich ML + the monitoring
  # stack could all throttle at once; that premise (plan for simultaneous high) is what
  # the owner retired.
  MODULES.system.limits.memoryBudget = "23G";
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
  # PLAN §3: auditd + execve keys for the code-running class (hermes IS the agent uid;
  # matrix-synapse's tree is static so execve is near-silent) + the
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

  # Phone SSH (keeps working after audit #9): Termius authenticates with the key in
  # users/herdr-mobile.pub, provisioned declaratively above and on akos01/hermes/datalab.
  # The Moshi/Herdr mobile pairing pages are retired 2026-11-14 (audit #9): the modules,
  # their ports (8470/8471) and their Traefik routes are deleted from the tree - enabling
  # them is no longer expressible here.

  # PLAN §7: east-west service graph in ENFORCE on this host (2026-11-13 audit flipped
  # `enforce` deliberately; the stale "observe mode, flip after a week of sg-seen" gate
  # prose was what was wrong - audit finding #12) + the passive Suricata tap (hp is the
  # tailnet aggregation point - one tap is enough, akos01 added 2026-10-25). Undeclared
  # TCP still logs rate-limited "sg-seen" BEFORE the reject, so drift keeps showing up as
  # {unit="kernel"} |= "sg-seen" / {job=~".*suricata.*"} in Loki.
  MODULES.security.serviceGraph = {
    # 2026-11-12: independent nftables hook survives VPN rule reordering.
    enforce = true;
    # wt0 joins tailscale0 as a tap (2026-11-12): the owner reaches hp over
    # NetBird too, and enforce's default treats wt0 as outbound-only - leaving
    # it there would drop NEW netbird inbound (SSH included), a silent
    # regression against today's live `-i wt0 -j ACCEPT`. Tapped, netbird
    # traffic must still match a declared edge; netbird's own ACLs layer on
    # top. akos01 is NOT enrolled in netbird, so it keeps the stock pair.
    taps = ["tailscale0" "wt0"];
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
      {
        name = "airlab-builder";
        # ssh-ng dials to r4unb02.airlab ride akos01's advertised transit /32, so OUR
        # tailscale0 tap sees them as outbound SYNs to a non-tailnet IP - undeclared,
        # that is SG-DRIFT on every nix offload (AGENTS Rule 1, both-roles).
        ports = [22];
        from = ["172.18.2.21"];
      }
    ];
  };
  # 2026-11-12: hp is the fleet's PUBLIC door (Cloudflare tunnel + funnel), so it also
  # runs the two public-facing observers: the Suricata loopback DPI tap on Traefik's
  # public entry ports (suricata.edge) and Traefik's JSON access log feeding the
  # edge-analytics Alloy pipeline. acceptFleetPush makes hp's Loki the aggregator every
  # peer's fleetPushTargets land in (the tailnet firewall rule lives in loki.nix).
  MODULES.security.serviceGraph.suricata.edge.enable = true;
  MODULES.networking.traefik.accessLogs.enable = true;
  MODULES.services.loki.acceptFleetPush = true;

  MODULES.security.audit.execUsers = [
    "postgres"
    "hermes"
    "matrix-synapse"
  ];

  # Coroot: node-agent only on hp (2026-10-26: the server half - UI + ClickHouse - was
  # disabled here and aggregation moved to akos01, the fleet's single Coroot server).
  # The agent pushes over Tailscale to akos01's collector (derived serverHost), hp is
  # visualised in that server's UI (coroot.<akos01's domain>); the old per-host servers
  # (2026-10-25) left the hp-local data in the now-orphaned coroot-data and
  # coroot-clickhouse-data docker volumes. Loopback OTLP emitters (open-webui)
  # key off coroot.enable and switch their trace export off on this host by themselves.
  MODULES.services.coroot.agentEnable = true;
  # Coroot RCA -> Postgres metrics for this box's cluster (role+extensions provisioned by
  # postgresql.nix; credentials go into Coroot's per-app form once per monitored instance).
  MODULES.services.postgres.corootIntegration.enable = true;

  # Coroot alerting lands HERE, where the talking parts of the fleet live: a webhook
  # receiver (PORTS.corootAlerts, tailscale0-only) that posts every Coroot alert/incident
  # into a Matrix room as the @coroot bot - one message for me (@akos) plus an @hermes
  # mention asking the agent to summarize what happened and diagnose it (the agent dials
  # akos01's Coroot API/MCP over the one pinned egress hole for real evidence). hp is the
  # receiver only; the akos01 server half of the wiring derives automatically, and
  # coroot-alert-configure registers the integration on akos01 hourly - no UI step.
  # RUNBOOK-coroot-alerts.md: the sops secrets. (modules/services/coroot-alerts.nix)
  MODULES.services.corootAlerts.enable = true;

  # n8n, the n8n-sandbox runner and LibreChat were removed from the fleet on 2026-10-24
  # (PLAN.md §1.5) - the chat UIs that remain are Open WebUI and Omniroute's own.

  # Paseo (hub + relay + paseo-hermes, formerly enabled here - RUNBOOK-paseo.md) and
  # litellm were retired fleet-wide on 2026-11-11: herdr (modules/services/herdr.nix)
  # replaced the Paseo hub/machine control plane, OmniRoute replaced litellm as the
  # gateway. The enable flips are gone; the modules stay for their pass-through parts
  # (see the ports note below) until the runbook/secret cleanup lands.

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
    defaultModel = "futurelab/qwen3.8-flash-next";
    smallModel = "futurelab/qwen3.8-flash-next";
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
  # Reachability is through the Cloudflare Tunnel (websocket + XEP-0156 host-meta on
  # xmpp.akosp.app; the old IPv6-direct design died because TU Wien drops inbound v6 and the
  # bridge cannot do SRV - the header of modules/services/xmpp.nix carries the 2026-11-15
  # measurements). The DNS-01 cert from Let's Encrypt still fronts direct 5222/5269 for
  # tailnet/LAN clients. Accounts come from sops (xmpp/*_password), hashed into Prosody once
  # at first boot. Matrix side: the jabber bridge above. Runbook: RUNBOOK-xmpp.md.
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

  # Trilium Notes (https://triliumnotes.org) as the knowledge base - https://trilium.hp on the
  # tailnet. The ETAPI token was created in the UI and stored in sops (trilium/etapi_token), so
  # Hermes reads and writes notes through it (see trilium.nix).
  # Retired by the owner during the 2026-11-12 review; keep its stored data.
  MODULES.services.trilium.enable = false;
  MODULES.services.trilium.etapiTokenSecret = "trilium/etapi_token";
  # Settings -> AI comes up with this host's gateway (OmniRoute) as the provider on the shared
  # omniroute_api_key inference key (trilium.nix's `gateway` options for the seeding mechanics;
  # a dashboard-minted scoped key is the cheap tightening step - the key lands in document.db in
  # plain text). Seed-once semantics, so the module re-seeds exactly the old litellm-id'd entry.
  MODULES.services.trilium.gateway.enable = false;

  # Joplin (https://joplinapp.org), side by side with Trilium for the same job - https://joplin.hp
  # on the tailnet: the Joplin DESKTOP streamed from lscr.io/linuxserver/joplin. The Hermes
  # comparison is API vs FILES: Trilium goes through ETAPI (above), while Joplin syncs its notes
  # as plain markdown into /var/lib/hermes/joplin, which Hermes reads and writes directly - the
  # container writes with the hermes uid, so both sides own every file (joplin.nix). First-boot
  # steps are in the syncDir option's text: sync target "File system", path /joplin-sync,
  # auto-sync on. No browser login (webUser = null, 2026-10-27: every tailnet peer is akos' own
  # device, so the nginx basic auth guards nothing a determined-enough local isn't already
  # trusted with; see the option's caveat about Joplin plugins before widening the tail).
  # AI chat is not seeded the way Trilium's gateway provider is - if wanted, Options -> AI with
  # http://127.0.0.1:<PORTS.omniroute>/v1 and an inference key minted on the dashboard.
  MODULES.services.joplin = {
    enable = true;
    # 2026-11-12: a streamed desktop with plugins is code execution; require
    # the module's generated password even on the private overlay.
    webUser = "akos";
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
  # Retired by the owner; disabling the units does not delete the archive.
  MODULES.services.paperless.enable = false;
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

  # Networking: NetworkManager owns DHCP (its own profiles are connected and
  # already hold the leases + the resolvconf records; measured 2026-11-15: NM had
  # .232 on the WAN NIC while a legacy dhcpcd held a SECOND concurrent lease .235
  # on the same interface plus one on wlo1 - profiles/global pulled NM in for the
  # TU campus, dhcpcd's mkForce from before that was never retired). The microvm
  # bridge keeps systemd.network enabled, and NixOS warns (correctly) when dhcpcd
  # is also switched on with a networkd-configured stack: with dhcpcd gone the
  # duplicate-managed-interface warning is gone because there is no second client.
  # dhcpcd's bridge/tap deny-list (microvm-host.nix) stays as a no-op safety net.

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
  # RE-ENABLED 2026-11-11. The 2026-11-09 teardown blamed unreachability, but that was
  # never the problem: r4unb02.airlab (172.18.2.21) rides akos01's tailscale transit /32
  # route (table 52) and answers TCP 22 today, and the shared nix-builder key authenticates
  # from akos01 fine. What actually failed ssh-ng was hp having NO host-key pin for the box
  # ("Host key verification failed" is what the daemon logs as "failed to start SSH
  # connection") plus the dangling identity symlink the disabled state left behind. Both
  # fixed in modules/nix/builders/airlab.nix (pinned identity + ssh/airlab-known-hosts,
  # keys cross-checked against akos01's and the laptop's pins and a fresh hp keyscan).
  # (The user's hunch said netbird; netbird is up here but not in the path - the route is
  # the tailnet's.)
  MODULES.nix.builders.airlab = true;

  # datalab agent sessions, 2026-11-11: hp hosts the ssh into the TU cluster inside tmux
  # so phone/laptop disconnects stop datalab's idle-reaper from killing the agent, while
  # the connection still ends WITH the harness (modules/services/datalab-harness.nix owns
  # the mechanics; tuvpn.boot keeps the tunnel up 24/7 - it is already this box's job).
  # The pi/opencode PATHs were verified against a plain non-login `ssh datalab`.
  MODULES.services.datalabHarness = {
    enable = true;
    user = "alexander.lampalzer";
    knownHosts = lib.removeSuffix "\n" (builtins.readFile ../../users/datalab-known-hosts);
    harness = {
      pi = {};
      opencode = {};
      # cmd "" = no agent, no remote tmux: a plain login shell on datalab, living and
      # dying with its dl-shell core terminal like every harness (reaper-safe).
      shell.cmd = "";
      # UltraTrainer (the A2RL video-training web app), 2026-11-13: spawned like any
      # harness (herdr menu row / `ultra-trainer` in a dl terminal / datalab-harness
      # ultra-trainer), runs `./run.sh` on the head with UT_PORT pinned to the number
      # hp's persistent loopback tunnel binds (PORTS.ultraTrainer; one port both ends).
      # The UI then answers at https://ultra-trainer.datalab.hp for the whole tailnet
      # WITHOUT any browser-side -L forward; until it is spawned the tunnel is up but
      # nothing listens head-side, so the site 502s - spawning from the menu is the
      # on-switch (the app keeps training jobs alive in its harness-ultra-trainer tmux
      # across phone disconnects, like every harness).
      ultra-trainer = {
        cmd = "cd ~/ultra-trainer && exec ./run.sh";
        portEnv = "UT_PORT";
        port = config.PORTS.ultraTrainer;
      };
    };
    # hp's third herdr identity (see the herdr block above: users.datalab +
    # machines.hp-datalab): every pane of that server execs the pinned cluster ssh
    # directly, the TU keepalive IS the terminal. Same trust set as hermes/root (one
    # human owns all keys; revocation = delete the line, redeploy).
    terminalAccess = {
      enable = true;
      authorizedKeys = [
        (lib.removeSuffix "\n" (builtins.readFile ../../users/akos-laptop.pub))
        (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-hub.pub))
        (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-mobile.pub))
      ];
    };
  };

  # The phone's ssh client keys its saved hosts by hostname, so it cannot hold hp twice
  # (root@hp and hermes@hp already exhaust it... one name, one entry). The alias gives
  # datalab its own name for the SAME sshd + tailnet IP: the phone adds
  # datalab@datalab.hp and lands in the pane-shell account. No router, no listener -
  # one address= record in the hp zone (modules/networking/dns.nix aliases).
  MODULES.networking.dns.aliases = ["datalab"];

  # The robot's UltraTrainer on the tailnet, 2026-11-13: hp dials r4uai01 through the
  # hub's herdr catalog identity (herdr-r4uai01 -> apapp@10.210.0.50 over the lab netbird
  # route, pinned keys, hub key via the Match-root rule) and republishes the app's port
  # on loopback; Traefik serves https://ultra-trainer.r4uai01.hp with a step-ca cert
  # (same "ultra-trainer" name as the datalab instance, one less spelling to remember).
  # Spawn-side: `ultra-trainer` runs ON r4uai01 (its ~/.local/bin launcher, tmux
  # attach-or-start, UT_PORT=8148 - the module header carries the exact one-time manual
  # block; r4uai01 is Ubuntu, outside this flake). The robot-side code is untouched by
  # hp - a reboot or lab power cycle needs NO tunnel restart here (Restart=always
  # re-dials) and no app start there (spawn it from the phone/laptop menu as always).
  # 502 until spawned, by design; the training outlives the pane via the robot's tmux.
  MODULES.services.labWebTunnels = {
    enable = true;
    # sshHost spelled out: the attr keys the APP (a machine can host several web UIs),
    # the alias keys the MACHINE - the module's "herdr-<attr>" default only fits when
    # the two coincide.
    tunnels."ultra-trainer-r4uai01" = {
      sshHost = "herdr-r4uai01";
      subdomain = "ultra-trainer.r4uai01";
      port = config.PORTS.ultraTrainerR4uai01;
    };
  };
}
