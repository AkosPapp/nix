# Security audit 2026-11-12/13 — fleet working-tree review + hp/akos01 deploy

Scope: full audit of the working tree (staged + unstaged delta vs HEAD
8152057, ~9.2k insertions / 78 files), live inspection of hp and akos01
over the tailnet, plaintext-credential sweep (repo + both hosts),
supply-chain check of the flake.lock bump, then a supervised deploy and
first hardened-kernel boot of both servers. Verdict at deploy time:
**safe**; everything that broke during the rollout was caught, fixed and
redeployed within the session (fixes are in the tree, marked below).

## Deployment record

| host   | gen                                   | kernel now     | boot safety used                        |
|--------|---------------------------------------|----------------|-----------------------------------------|
| hp     | 437 (26.05.20261108.ac588ef)          | 6.18.60-hardened1 | systemd-boot oneshot (old gen 436 stayed default until verified) |
| akos01 | 276 (26.05.20261108.ac588ef)          | 6.18.60-hardened1 | grub-reboot oneshot, default pinned to 275 until verified |

Builds happened on legion5 per the owner's flow; closures were nix-copy'd
to the targets (deploy-rs remoteBuild then no-ops). akos01 had been
`nix-collect-garbage`'d which deleted the GC-rootless *input* drvs of the
already-copied closure — remote builds failed on a dangling
`qemu-aarch64-binfmt-P` input until that path was re-copied; cosmetic,
worth remembering as the deploy-rs + GC interaction.

## What the deploy changed (security-relevant delta actually applied)

- **Hardened kernel on both servers** (grafx 6.18.60-hardened1 via
  `MODULES.system.hardenedKernel`): PANIC_TIMEOUT=-1, INIT_ON_FREE,
  KSTACK_ERASE, UBSAN_TRAP, DEBUG_* validation set, LDISC_AUTOLOAD=n,
  PROC_KCORE=n, INET_DIAG=n, LEGACY_VSYSCALL_NONE, io_uring disabled by
  default, unprivileged userns disabled by default. ZFS 2.4.4 + ryzen-smu
  kmods compile and load against it (verified pre-deploy by full toplevel
  builds + first boot).
- **SSH ingress closed to the overlays** (unstaged `sshd.nix`
  `openFirewall=false` + `interfaces.tailscale0.allowedTCPPorts`): the
  deployed config had `-A nixos-fw -p tcp --dport 22` on EVERY interface
  of both servers — live on hp that meant the TU campus LAN **and its
  public IPv6** (2001:67c:d4c::/64) accepted key-auth SSH to root. Now:
  tailscale0 only (+ wt0 via the netbird guard on hp, per the
  "tailscale-or-netbird-only" policy).
- **mosh UDP 60000-61000 removed from LAN/WAN** (this audit's edit:
  `programs.mosh.openFirewall = false` in profiles/global.nix — the
  nixpkgs mosh module was the sole author of that world-open 1001-UDP
  hole on every host, while no host runs mosh-server) and re-opened
  **tailscale0-only** (`interfaces.tailscale0.allowedUDPPortRanges`,
  folded into the service-graph's UDP pass-list) to preserve the tailnet
  session plane. Verified: `iptables -S | grep 60000` now shows only the
  tailscale0 rule on both hosts.
- **Service graph flipped from observe to ENFORCE on hp+akos01**
  (`MODULES.security.serviceGraph.enforce = true`): independent nft
  inet-chain at priority 10 (runs after tailscale/netbird's own accepts,
  so their reordering can no longer bypass it), default-deny for
  undeclared TCP (reject) and UDP (drop) on the tapped interfaces. hp
  gained `taps = ["tailscale0" "wt0"]` in this audit (netbird inbound
  must speak the declared edges instead of the guard's blind
  `-i wt0 -j ACCEPT`; netbird's own ACLs stay the first gate).
  akos01 keeps wt0 outbound-only (not enrolled; its INPUT showed a
  vestigial wt0 ACCEPT with no wt0 device — now moot under enforce).
- **Owner retirements applied**: trilium + paperless disabled on hp
  (containers gone, data kept), joplin web auth re-required
  (`webUser = "akos"`), `moshiPair`/`herdrMobilePair` stay OFF (finding
  below), omp's futurelab-direct fallback chain removed (owner request —
  it retried the same cooling credentials), coroot server moved to
  akos01 with sops-generated admin bootstrap, new coroot-alerts receiver
  on hp (8144, tailnet-only, constant-time token, loopback Hermes).
- **nix supply hygiene**: `trusted-users` reduced to `root` on build
  hosts (the `builder` account — laptop-key reachable — was trusted,
  which is root-equivalent; 2026-11-12 review fix now deployed).

## Findings

### Fixed during this session

1. **HIGH — root SSH open on every interface of both servers (deployed
   config)** — key-only, but hp's TU LAN + public IPv6 made it
   internet-reachable. Fixed (sshd.nix overlay-only ingress; verified in
   live nixos-fw after switch).
2. **HIGH — UDP 60000-61000 world-open on every host** via
   `programs.mosh.enable`'s default `openFirewall`. Fixed → tailscale0
   only (LAN/WAN hole closed, tailnet plane preserved).
3. **HIGH (crash, first-boot) — firecracker microVM dead on the hardened
   kernel**: grafix sets `io_uring_disabled=1` and its sysctl only
   transitions 1→2, so the runner's default `io_engine=Async` failed
   `io_uring_setup(EPERM)` — `microvm@vm-agents` flapped 156x on hp's
   first hardened boot. Fixed: `microvm.firecracker.driveIoEngine =
   "Sync"` in hosts/vms/vm-agents.nix (guest boots, pingable, tailscale
   + coroot agent up inside).
4. **MEDIUM (stability) — transient deploy-races surfaced by the
   switch**, both self-healed and re-verified: prometheus-rules-reload
   failed once (prometheus was mid-start; restart succeeded), and hp's
   `coroot-alerts` receiver activated `inactive` on the first switch
   (start-order race vs network-online); it is `active` + listening on
   8144 since. If it ever comes up dead again after a switch,
   `systemctl start coroot-alerts` is the one-liner.
5. **MEDIUM (supply chain) — r4unb02.airlab host-key pin failure**
   (pre-existing, found while offloading the hardened-kernel build): the
   `environment.etc."ssh/airlab-known-hosts"` pins do NOT match the
   builder's current keys (ed25519 AND rsa differ), so nix offload from
   legion5 via the sops builder identity fails closed (the pinning works
   as designed — loud failure, no TOFU). Needs a re-keyscan from a
   trusted position and a pin update; the daemon path on the servers
   uses the same file (hp dials akos01's transit /32 today).

### Coroot incident sweep (2026-11-14, owner-reported)

| incident | verdict | action |
|---|---|---|
| `coroot-alerts` "Elevated error rate 100%" since Nov 13 12:05 | REAL bug: Synapse 1.164.2 (hp switch Nov 13 00:44) dropped the deprecated `POST /_matrix/client/v3/create_room` snake_case alias; the receiver 404'd `M_UNRECOGNIZED` on every webhook POST, coroot retried per minute and counted them as app errors. Secondary: the token-refresh retry re-issued WITHOUT the Authorization header (401 at every MAS expiry). | `receiver.py`: `createRoom` + `login()` before retry; DM rooms created and the room cache seeded live on hp 18:34 (journal zero errors since; incident auto-resolved). Next switch redeploys the binary path via `restartTriggers`. |
| `suricata` / `suricata-edge` "new error in the logs" (442–880/h) | false alarm, and NOT the Alloy pipeline: coroot-node-agent tails whatever the unit holds open — Suricata keeps `eve.json` write-open, so raw EVE `event_type:"stats"` telemetry enters coroot as unit logs and the agent's JSON severity extractor keys on `error` substrings inside `stats.app_layer.error.*`/`capture.errors`. Loki never sees stats (the SG evePipeline drops them); journald carries no EVE lines. | `coroot.nix`: agent gets `--disable-json-log-parsing` exactly on hosts whose Alloy pipeline owns eve.json (suricata+loki both on); metrics/Loki streams untouched (Alloy reads the file directly). Live: both alert groups suppressed (204) until the switch. Side effect noted in the module comment: JSON severity off for nginx logs on those hosts. |
| `redis-immich` "High latency 100%" since Nov 11 | measurement artifact: 100% of eBPF-timed "requests" are ≤10s blocking waits (immich bull's BZPOPMIN 10 s timeouts, 584 k calls); redis itself healthy (eventloop 235 µs, fork 1.4 ms, slowlog max 13 ms, 0 evicted). Unit is `redis-immich@akos01`. | owner UI action (no community-API for per-app overrides, and `projects:` in the config file is the documented REPLACE trap): redis-immich → SLO Latency → custom objective bucket ≥15 s (or disable SLOLatency for it). |
| `syncthing` "failed to connect to 1 upstream service" (CRITICAL) | the failing peer is the PHONE (100.113.16.42:22000, 4512 failed connects/24 h — Android Doze drops the listener); the ipad has ZERO 22000 attempts in 7 d. The co-firing `system-immich` attribution is its loopback ML-worker dial at boot (3902/h during the Nov 13 switch). | owner UI action: raise/disable the `network-tcp-connections` rule for these apps (same sanctioned knob, same API gap). |
| `datalab-web-ultra-trainer` "High latency" | hp's `datalab-web-ultra-trainer.service` ssh -L tunnel into the UNMANAGED TU datalab head (UltraTrainer SPA); all 7 Nov-14 incidents self-resolved; live probes: 302 in 15–41 ms now. Head/VPN congestion + tiny request counts burn the default 500 ms@99 % SLO. | same owner UI SLO knob; no repo defect. |
| EE entitlement | owner supplied `COROOT-…` license + `org_…` cloud API key; both in sops (`coroot/license_key`, `coroot/cloud_api_key`). `MODULES.services.coroot.enterprise = true` on akos01: server ExecStart swaps to the hash-pinned `coroot-ee` v1.29.2 binary (verified: builds via the module, runs locally reporting "edition: Enterprise"; needs liblz4 — autoPatchelf'd), LICENSE_KEY via a 0400 sops template EnvironmentFile, cloud key as `${COROOT_AI…}`-style placeholder in the `--config` YAML (coroot `os.ExpandEnv`s it; the config is now assembled from `configFileFragments` so coroot-alerts' serviceAccounts and the enterprise corootCloud block coexist; NEVER add `projects:` — REPLACE trap). "AI disabled" lifts by setting `MODULES.services.coroot.ai` (null by default; snippet in the module docs). | lands with the deploy. |

### Dispositions (2026-11-14 remediation pass)

| # | status | action |
|---|--------|--------|
| 1 | closed | owner policy confirmed: SSH ingress stays overlay-only (tailscale0; wt0 via the netbird guard). |
| 2 | closed | mosh UDP tailscale0-only confirmed live (`iptables -S nixos-fw` both hosts, 2026-11-14). |
| 5 | closed | pins re-verified byte-for-byte from a trusted position 2026-11-14 (keyscan of the transit /32 from akos01 == airlab.nix pins == deployed /etc/ssh/airlab-known-hosts); `ssh builder@r4unb02.airlab` from akos01 exits 0. The audit's mismatch was a stale deployment/pre-update pin window, not drift. Dated close-out note in `modules/nix/builders/airlab.nix`. |
| 6 | closed | Loki `fleetPushFrom`: hp's push ingest is source-restricted to the declared pusher IPs (derived from the fleet's own `fleetPushTargets`), loopback read stays. See `modules/services/loki.nix` + the service-graph `loki-ingest` edge. |
| 7 | closed | per-consumer OmniRoute keys: `MODULES.services.omniroute.keys` mints/maintains one gateway key per declared consumer via the management API; values land in `/var/lib/omniroute/keys/<name>` (0600 root, in-repo of the replicated state dir, NOTHING in sops for on-gateway consumers) and re-mint automatically when lost; consumers read the file. Follow-up 2026-11-15 (owner: "remove the old litellm key"): the sops `omniroute_api_key` value WAS the gateway row named `litellm`; it now holds the value of a purpose-named row `omp-laptops` (minted via `omniroute-mint-key`, rotated into sops, deployed, verified live). The `litellm` row itself stays until its `lastUsedAt` goes stale (open pre-rotation sessions - revoking earlier 401s every laptop harness mid-flight); revoke on the dashboard then. Shared `omniroute_api_key` survives ONLY as the off-gateway-host harness credential (laptop). See omniroute.nix header. |
| 8 | closed | `AkosPapp/hermes-agent-fork` created as a REAL fork of NousResearch/hermes-agent; branch `nix` rebuilt (upstream 4ad61cee + the one 12-line venv_sync.py hunk = dd9ef8eb, tree-identical to upstream+fixup — the 15 gitignore-skipped files are back); flake input re-pinned to the new repo, old AkosPapp/hermes-agent superseded (delete when convenient). |
| 9 | closed | `moshi-pair.nix`, `herdr-mobile-pair.nix`, `packages/moshi-hook.nix`, `packages/herdr-mobile-pair.py` DELETED; ports 8470/8471 freed; all references and stale docs gone. Phone SSH (users/herdr-mobile.pub + Termius) unaffected — owner keeps phone root SSH as the accepted #10 tradeoff. |
| 10 | accepted | owner keeps phone SSH on the overlay (dated above); pairing-page *mechanism* deleted (#9), revocation stays manual for the off-flake robots. |
| 11 | closed | akos01 `/root/.ssh/.ssh/*` private keys deleted 2026-11-14 (md5s did NOT match the sops builder key — they were the *laptop's* legacy user keys, now also deleted from legion5 `~/.ssh/`; agent-forwarding logins unaffected, verified post-delete on both servers). |
| 12 | closed | observe-mode prose updated to the ENFORCE ledger in hosts/akos01, hosts/hp and the `serviceGraph.enforce` docs. |
| 13 | closed | scratch probe files deleted (contents verified credential-free first). |
| 14 | closed | comment fixed: the laptop RSA key commented `akos@nixos` (SHA256:bS9Kf…, byte-identical to users/akos-laptop.pub's RSA blob) IS hand-trusted in legion5's authorized_keys; the `akos@laptop` ed25519 line is a different key. Trust is out-of-band, and profiles/global.nix now says so. |
| 15 | superseded | io_uring: the hardened kernel now ships a build-time revert of the grafix `io_uring_disabled=1` latch (`MODULES.system.hardenedKernel.ioUring = true`, default) — io_uring works again, the sysctl regains 0/1/2 semantics. Requires a kernel rebuild + reboot; until then firecracker stays Sync. |
| 16 | closed | no config existed to kill: the dialer was a leftover process of this audit session; last SYN 2026-11-13 12:01:52, zero since (hp sg-seen spine + 60 s `ss` sampling on legion5). |
| 17 | closed | coroot 8080/4317 inbound edges tightened from 100.64/10 to the declared agent peerIPs in the service graph. |

### Open — recommendations (not deploy-blocking)

6. **MEDIUM — Loki `acceptFleetPush` exposes the FULL unauthenticated
   Loki API (read + write, any labels) to every tailnet node**, not just
   the pushers (`auth_enabled=false`, bind 0.0.0.0 + fw open to
   100.64/10; service-graph edge `loki-ingest` uses all-peer `from`).
   Any compromised tailnet node can read hp's journald spine and forge
   stream labels feeding the fleet dashboards/SG logic. Fix:
   `fleetPushFrom` list of pusher IPs on the firewall/edge, or split the
   read listener back to loopback behind Grafana.
7. **MEDIUM — `omniroute_api_key` is now the shared default credential
   for paseo installers, trilium (plaintext in synced document.db),
   hermes and open-webui.** The gateway *management* token was correctly
   rotated out of hermes' env (good), but a leak from any installer
   script or synced note = fleet-wide gateway access, un-revocable per
   consumer. Mint per-consumer virtual keys (the modules' own docs
   recommend exactly this) and change the option defaults.
8. **MEDIUM — hermes-agent fork pin is an orphan snapshot, not
   "one commit on top of upstream"** (flake.nix:53). The base commit
   c01b4549 has `parents: []` and its tree silently lacks 15 files that
   upstream 4ad61cee tracks (font .woff2s, get-windows.d.ts,
   plugin.runtime.js, userStories.json, …) because they match upstream's
   .gitignore at copy time. Benign for the modules' runtime path today,
   but the provenance claim in the comment is wrong — rebuild the fork
   as a real branch (`git checkout -b nix 4ad61cee` + fixup commit).
9. **MEDIUM — retired pairing pages remain in the tree, one still
   reachable through Traefik**: `MODULES.services.moshiPair` /
   `herdrMobilePair` default `user = "root"` and mint an
   **unauthenticated** (pairTokenFile=null) root-SSH enrollment QR; hp
   disables them, but `hosts/hp/default.nix` (~line 415) still documents
   the moshi pairing page as live and `traefik.services.moshi`/
   `herdr-mobile` route blocks render for any host that re-enables the
   flags. Delete the modules (or default their `user` to a non-root
   account + require the pair token) and drop the stale docs.
10. **LOW/MEDIUM — root SSH now depends on the overlay**: the hub key
    (`herdr/hub_ssh_key`, sops) and `herdr-mobile.pub` (phone) are in
    root's authorized_keys on every fleet box incl. off-flake robots
    (registry = a comment in hosts/hp) — revocation there is manual and
    will drift. Accepted owner tradeoff (dated), but the robots should
    move under the flake.
11. **LOW — stray plaintext key copies on akos01**: `/root/.ssh/airlab_key`
    and `/root/.ssh/private_key` are md5-identical copies of the
    sops-managed `nix-builder/private_key` (0600 root, but unmanaged —
    they survive switches and defeat rotation). Delete on akos01 (hp is
    clean: its /root/.ssh/id_ed25519 is a symlink into /run/secrets).
    The laptop's legacy `~/.ssh/id_airlab_builder` + `airlab_key`
    equivalents deserve the same pass at the next visit.
12. **LOW — `enforce = true` contradicts the retained "observe mode /
    flip after a week of sg-seen" comments** in hosts/hp + hosts/akos01
    + the module's option description; update the comments (this audit
    flips it deliberately; the stale prose is what's wrong).
13. **LOW — probe scratch files at the repo root** (`datalab:22`,
    `r4uai00:22`, `r4uai01:22`, `lab-dns`, `lab-ping`): untracked, not
    gitignored — `make stage` (`git add .`) will commit them. Contents
    checked: connection-probe output only, no secrets. Delete or gitignore.
14. **LOW — `profiles/global.nix` comment claims akos-laptop.pub is
    trusted for `akos@legion5`; it is not** (akos there trusts
    hub+mobile only). The comment is wrong (or a key is missing) —
    fix whichever way is intended.
15. **INFO — hardened-kernel side effects to remember**:
    `kernel.unprivileged_userns_clone=0` (root-run `PrivateUsers` units
    are fine — verified live; but rootless podman / browser-sandbox-style
    unprivileged userns dies until `USER_NS_UNPRIVILEGED=y` or the sysctl
    is re-enabled — deliberately not set fleet-wide), io_uring off
    (firecracker Sync-only; any future io_uring user needs the same
    treatment or a kernel opt-in), INET_DIAG off (modern `ss -i` bits
    degraded in guests), PROC_KCORE off.
16. **INFO — laptop→hp:20132 dialer** (a process on legion5 SYN-dials the
    omniroute metrics port every ~30s; it's loopback-bound on hp and was
    already refused pre-switch — enforce just made it visible via
    sg-seen). Find and kill the zombie config on legion5.
17. **INFO — coroot inbound edge allows the full 100.64/10 for 8080/4317**
    where `peerIPs` (declared agents) would suffice; coroot-alerts
    receiver parses alert `url`s (display only today — links not
    fetched, so no SSRF) and its Hermes-agent diagnose path lets a
    token-holder's alert text seed agent-authored Matrix messages (same
    trust class as the already-live hermes chat path). Tighten when
    convenient.

## Verified clean

- **No plaintext credentials anywhere in the repo diff or the working
  tree**: `sops/secrets.yaml` is 96/96 `ENC[AES256_GCM]` (diff adds only
  ENC blocks + metadata); every `*Secret`/`*Token`/`password*` identifier
  in modules/hosts/users resolves to a sops key name or a
  `/run/secrets` path, never a value; no `BEGIN PRIVATE KEY` anywhere
  tracked (the only one is the git-ignored `tmp/` host key with its
  age-encrypted sibling); `pki/` ships certs only (`generate.sh` keeps
  keys outside); `dashboards/*.json`, `mcp.json`, tests, scripts and the
  colon-named scratch files contain no credentials (swept sk-/ghp-/AKIA/
  JWT/URL-cred patterns); `programs.ssh.extraConfig` adds
  `StrictHostKeyChecking=yes`, no GlobalKnownHostsFile weakening.
- **Secret wiring on the live hosts**: every sops target on hp/akos01 is
  0400/0440 service-owned; no world-readable /etc file contains
  credential-looking assignments; the docker-env sweep found only the
  expected container secrets inside root-only inspect;
  `attic/akos/token` netrc + rendered templates 0400; new
  `coroot/agent_api_key`, `coroot/alerts_token`,
  `coroot/alerts_admin_api_key`, `matrix/coroot_password` exist in sops
  and mount correctly (key/secret completeness cross-checked per host:
  all referenced keys present; ~38 stale-but-unused sops keys listed for
  a pruning pass, incl. litellm remnants and dead bookstack/nextcloud/
  mcp-context-forge entries).
- **Flake.lock moves reviewed**: nixpkgs 26.05 + nixpkgs-unstable +
  sops-nix + disko + niri + my-nixvim + hermes-agent (fork, see #8) +
  gpu-unlock PR branch (documented). `packages/paseo/package-lock.json`:
  0 non-registry `resolved` URLs. `checks = deployChecks` passes.
- **vm-agents guest**: tap-only NAT (`forwardPorts = []`), strict-host
  sshd, no inbound surface; joins tailnet as its own peer.

## Posture summary (live, post-deploy)

hp: 22@tailscale0+wt0-guard only; 5222/5269/5281 public (intentional
federation over v6 — CORRECTION 2026-11-15: the v6 inbound never worked, TU Wien
drops it; 5281 is gone and c2s/s2s are tailnet/LAN-only, public clients ride the
tunnel as WebSocket — see modules/services/xmpp.nix header + RUNBOOK-xmpp.md);
traefik 80/443 tailnet-only; public door = the
Cloudflare tunnel on akosp.app (id.akosp.app 200, m.akosp.app 302
verified over the tunnel). akos01: zero global TCP accepts, UDP
{41641, 60000-61000@tailscale0} only. Both: fleet nft enforce chain
loaded, 0 failed units, ZFS healthy, deploy-confirmed (magic-rollback
canary passed), hardened kernel running, old generations selectable for
rollback.
