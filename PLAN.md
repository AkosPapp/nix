# hp containment & resource plan (2026-10-24)

One document for everything decided this session. Supersedes `ZFS-BACKUP-PLAN.md`
(deleted; contents folded into §4). `SECURITY-AUDIT-2026-10-24.md` remains as the
findings list this plan acts on.

Verified against this nixpkgs (26.05):

| thing                                        | status                                                                            |
| -------------------------------------------- | --------------------------------------------------------------------------------- |
| `security.audit` + `security.auditd` modules | present (`nixos/modules/security/audit*.nix`) — auditd **not currently running**  |
| `falco` package                              | **gone** from nixpkgs (only `falcoctl` remains) — not an option without vendoring |
| `gvisor` (runsc)                             | present                                                                           |
| `krun`                                       | present                                                                           |
| cgroup v2 on hp                              | live, `cpu.max`/`memory.high`/`pids.*` files exist per unit                       |
| `MODULES.virtualisation.podman`              | exists, unused; `virtualisation.docker` enabled                                   |
| microVM support                              | `microvm.nix` is **not** a flake input yet                                        |
| hp capacity                                  | 8 cores, 21 GiB RAM, zpool 241 G free                                             |

---

## 1. Layer 1 — resource ceilings (the fork-bomb answer)

### 1.1 What actually does what

| control                      | file in cgroup v2          | fork bomb              | memory hog              | cpu hog       | disk hog    |
| ---------------------------- | -------------------------- | ---------------------- | ----------------------- | ------------- | ----------- |
| `TasksMax=`                  | `pids.max`                 | **kills it**           | —                       | —             | —           |
| `MemoryHigh=` / `MemoryMax=` | `memory.high` / `.max`     | —                      | **throttle then OOM**   | —             | —           |
| `CPUQuota=`                  | `cpu.max`                  | slows its respawn rate | —                       | **caps it**   | —           |
| `CPUWeight=` / `IOWeight=`   | `cpu.weight` / `io.weight` | —                      | —                       | fairness only | needs `bfq` |
| `MemorySwapMax=0`            | `memory.swap.max`          | —                      | stops swap thrash       | —             | —           |
| `systemd.oomd`               | `oomd`                     | —                      | userspace OOM w/ policy | —             | —           |

`TasksMax` is the specific answer to "someone RCEs litellm and forks": a fork bomb
cannot escape its `pids` cgroup — `clone()` returns `EAGAIN` inside the unit, the
kernel scheduler and every other service never notice. On v1 this leaked (thread
counting bugs); on v2 it's exact.

### 1.2 Design: a `LIMITS` registry, mirroring `PORTS`

Same pattern as `modules/networking/ports.nix` — one attrset, everything derived and
asserted from it. `modules/system/limits.nix` (new):

```nix
options.LIMITS = mkOption { type = types.attrsOf (types.submodule { options = {
  tasks   = mkOption { type = types.nullOr types.ints.positive; default = null; };
  cpu     = mkOption { type = types.nullOr types.str;           default = null; };  # "200%"
  memHigh = mkOption { type = types.nullOr types.str;           default = null; };  # "768M"
  memMax  = mkOption { type = types.nullOr types.str;           default = null; };
};});};
```

A small `mkService` helper applies it to any `systemd.services.<name>` unit via
`serviceConfig`. Assertions, computed the way ports.nix does:

- **Σ `memMax` of all enabled services ≤ 18 G** (21 GiB box). Catches drift at eval
  time, not at 03:00 when OOM kills prometheus.
- `memHigh < memMax` for every entry.
- Warn (not fail) if a service appears in `PORTS` but not in `LIMITS` — coverage must
  be an explicit choice, same as the port registry.

### 1.3 Per-service numbers

Tasks counts threads too, and torch/immich/vllm spawn thread armies — a 64 cap there
is a self-DoS, not a sandbox. GPU/LLM units get slack; boring units get tight caps.

| service                                | TasksMax | CPUQuota | MemoryHigh | MemoryMax | notes                                              |
| -------------------------------------- | -------- | -------- | ---------- | --------- | -------------------------------------------------- |
| synapse + MAS + bridges                | 192      | 200%     | 1536M      | 2G        | synapse threads heavily; MAS is python             |
| postgresql                             | 64       | 200%     | 1G         | 1536M     | `shared_buffers` sized in postgresql.nix           |
| litellm                                | 256      | 150%     | 512M       | 768M      | uvicorn workers, no threads concern                |
| traefik                                | 128      | 100%     | 256M       | 384M      |                                                    |
| ollama                                 | 512      | 700%     | 8G         | 10G       | **sized to the loaded model, not hope** — see 1.5  |
| vllm                                   | 512      | —        | —          | —         | container; capped at slice level (§1.5)            |
| immich (server/ML)                     | 256      | 200%     | 1G         | 1536M     | ML does not need the moon                          |
| grafana                                | 128      | 100%     | 384M       | 512M      |                                                    |
| prometheus                             | 128      | 200%     | 2G         | 3G        | tsdb churns; give it room                          |
| loki                                   | 128      | 200%     | 2G         | 3G        |                                                    |
| n8n + sandbox                          | 256      | 200%     | 768M       | 1G        |                                                    |
| trilium / librechat / homepage / searx | 128      | 100%     | 256M       | 384M      | boring-tier, one default                           |
| sftpgo / transmission                  | 128      | 100%     | 256M       | 512M      | transmission: `IOWeight=10` (bfq, §1.6)            |
| matrix bridges (mautrix-*)             | 64       | 50%      | 192M       | 256M      | one process each                                   |
| hermes-agent / paseo / opencode        | 256      | 100%     | 512M       | 768M      | already has `sandbox` in hermes-agent.nix          |
| dnsmasq                                | 16       | 25%      | 32M        | 64M       |                                                    |
| zfs-exporter, node-exporter, smartd    | 16       | 10%      | 32M        | 64M       | monitoring must survive everyone else              |
| **floor for the host itself**          | —        | —        | —          | —         | sanoid/syncoid, journald, systemd: ~2 G unreserved |

Numbers are a starting table, yours to tune; the assertion is what keeps them honest.

### 1.4 `systemd-oomd` — decide deliberately

NixOS default: **disabled**. Enabling it (`systemd.oomd.enable = true`) gives a
userspace OOM that acts on PSI pressure _per cgroup_ with a policy, i.e. it kills the
right thing before kernel OOM picks something random. Two risks: it can kill ollama
mid-inference (a model load spikes pressure legitimately), and it fights `MemoryMax`
semantics. Recommendation: **enable it with `swapUsedTarget` only and `UserSwapOut`
off** once §1.3 has run clean for a week; kernel `memory.max` is the wall meanwhile.

### 1.5 The docker/vllm carve-out

just disable librechat, n8n vllm, im not using them any more, you can even delete the config for all i care

`librechat`, `n8n-sandbox`, `vllm` etc. ride under `docker.service` — per-unit caps
never reach them, and `virtualisation.oci-containers` has no cgroup options. Put the
whole daemon in its own slice:

```nix
systemd.services.docker.serviceConfig.Slice = "containers.slice";
systemd.slices.containers = { serviceConfig.MemoryHigh = "6G"; MemoryMax = "8G"; TasksMax = 2048; };
```

Per-container: `--memory` / `--cpus` (oci-containers supports it via
`extraOptions`/`settings` in 26.05). §3 (podman) makes this moot per-container.

`ollama` deserves the one exception rule: `MemoryMax` below model+KV size doesn't
sandbox, it kills inference at 3 a.m. Two safe options — (a) quota only (`CPUQuota`
`TasksMax`, no `MemoryMax`, trust model files on disk), (b) `MemoryMax` = largest
loaded model + 20% headroom, and the `LIMITS` assertion forces you to look when you
add a bigger one. Start with (a), move to (b) when the model set stabilizes.

### 1.6 IO — the weak one

`IOWeight=` requires **bfq** on the target queue. hp's root is NVMe; default scheduler
there is `none`. Options: set `requestQueue.scheduler = "bfq"` on the nvme queues (a
little latency on the single spindle-of-one disk), or accept that disk contention is
not your threat (the 64 G docker + 49 G transmission dirs are the only real IO
abusers, and transmission is the one worth throttling: `Nice=19 IOSchedulingClass=idle`
on its unit is 80% of the benefit for zero config). Recommendation: the latter, skip
bfq.

### 1.7 Make the invisible visible (so you see the culprit, not the victim)

- `node-exporter`: `--collector.pressure` → PSI cpu/memory/io per cgroup (add to the
  node-exporter args — check whether the existing nixos `services.node-exporter` has
  the collector enabled; it is off by default in some versions).
- Grafana alerts (you already run both):
  - `delta(node_pressure_memory_waiting_seconds_total[1m]) > 0.15` sustained → who
    is in some-mem pressure? join on cgroup label.
  - `container_memory_failcnt` / `pids` near limit → the offender is pinned at its
    cap — which means it is either mis-sized or misbehaving. That is the alert.
- This closes the loop on the requirement: throttle happens inside the offender, the
  victim (you) sees a Grafana event naming it.

---

## 2. Layer 2 — containment tiers

### 2.1 Tier model

try to make this modular and reusable, it would be nice if i could easily switch between the systemd jail and the microVM for a service without having to rewrite the whole config
id also prefer using microvm with firecracker for everything

| tier                         | mechanism                                                                         | isolation                            | what it stops                                                                                   | cost                  |
| ---------------------------- | --------------------------------------------------------------------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------- | --------------------- |
| **A. systemd jail**          | `ProtectSystem=strict` + `BindPaths` + `InaccessiblePaths` + per-uid egress chain | same kernel; uid + fs view + network | RCE: reading another svc's secrets, `psql -U postgres`, reaching its port, egress pivot         | near-zero             |
| **B. microVM**               | `microvm.nix` (cloud-hypervisor/qemu), dedicated kernel + uid space               | separate kernel                      | everything A stops, plus kernel exploits, cgroup/namespace escapes, whole-host resource capture | RAM/kernel dup per VM |
| **C. OCI (podman rootless)** | per-uid user namespace + CRIU-style checkpointing                                 | separate uid space on same kernel    | A-stops + host fs (store is in user's home)                                                     | image ops             |

`ProtectSystem=strict` alone is **not** isolation: it's a mount-namespace view, root
in one jailed service can still ptrace another if they share uid space. The pieces
that make Tier A real are (1) per-service users, (2) uid-based egress firewall,
(3) `RestrictAddressFamilies` / `RestrictIFaces` (new, 257+), and (4) `PrivatePIDs=`
(new in systemd 257 — a per-service PID namespace that makes "find my neighbour's
socket" impossible). hp runs systemd 260 → all of these exist. This is what the
`MODULES.security.jail` module wraps; `hermes-agent.nix` already implements the
pattern and is the template.

**The gap that makes Tier A mostly cosmetic today: Postgres unix-socket `trust`.**
Any jailed service can `psql -U postgres` and own every DB. Fix before jail work —
it's ~20 lines (scram auth + per-service roles in `profiles/postgres.nix`), and it's
also a prerequisite for the `n8n`/`librechat`/`immich` jail specs below (their egress
must say "postgres:5432 only", not "all of /run/postgresql").

### 2.2 Per-service assignment — target tier + rationale

Legend: **now** = what the service is today · **A/B/C** = target · **why** = what
drives the tier · **alt** = considered alternatives.

#### Code-running tier — this is the actual risk surface

| service                             | now                                               | target                                                           | why                                                                                                                                                                 | alternatives considered                                                                                                                    |
| ----------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **n8n-sandbox**                     | docker container (host network, rootful)          | **B** microVM                                                    | executes arbitrary JS from workflow triggers, DinD = root-adjacent by design; a container shares hp's kernel with it                                                | rootless podman+`--network=none` (still same kernel — insufficient); gVisor/runsc (packaged, but NixOS integration = glue on a niche path) |
| **n8n**                             | docker container                                  | **B** (same VM as sandbox, separate unit; or A if you accept it) | executes arbitrary workflow logic; it is the box's most reachable RCE surface (webhook triggers, public via traefik)                                                | Tier A jail + scram postgres (acceptable middle ground if VM feels heavy); podman rootless (halfway)                                       |
| **hermes-agent**                    | systemd, already jail'd (BindPaths, egress chain) | **A** (keep) → **B** candidate                                   | agent runs tool calls (code exec!) — the sandbox module proves the pattern; escalate to VM if the tool set keeps growing                                            | gVisor; B is a drop-in later since it's a single unit with a small state dir                                                               |
| **opencode / paseo / paseo-hermes** | systemd                                           | **B** (with n8n in a shared "agents" VM)                         | same class: LLM-directed execution                                                                                                                                  | A jail with `PrivatePIDs=` + no-net is a credible cheaper option if B's RAM cost hurts (21 G is tight)                                     |
| **librechat**                       | docker                                            | **A** jail (podman rootless = **C**)                             | user-facing app, DB-backed, not executing host code; LibreChat runs its own "code interpreter" container — that one must never see the host → podman rootless or VM | keep docker + slice caps (§1.5) is the lazy A                                                                                              |
| **litellm**                         | docker                                            | **A** jail                                                       | proxy, no exec surface, but holds every API key ⇒ treat as high-value RCE target                                                                                    | C (podman, trivial swap — same compose)                                                                                                    |
| **immich ML / vllm / ollama**       | docker / systemd / docker                         | **A**                                                            | no remote code (models ≠ code… unless you load GGUFs from the internet — see §2.5)                                                                                  | B is pointless: the GPU boundary forces these to stay host-side anyway                                                                     |

#### Data tier — classic services, jail and go

| service                                                | now     | target                      | jail spec (rw paths / allowed egress)                                                                                                                                                                                                                          |
| ------------------------------------------------------ | ------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **synapse + MAS + mautrix-***                          | systemd | **A**                       | rw `/run/.../synapse*`, ro egress: postgres:5432, self-loopback federation out on 8448, no general internet (federation via `matrix.org` well-known needs _in_, not out — media downloads are the exception: allow `* :443` or pin to known media hosts later) |
| **postgresql**                                         | systemd | **A** + scram (prereq)      | rw datadir only; egress: **none** (`IPAddressAllow=loopback`); `TasksMax=64`                                                                                                                                                                                   |
| **grafana**                                            | docker  | **A**                       | rw state; egress: prom:9090, loki:3100, loopback                                                                                                                                                                                                               |
| **prometheus + loki + alloy**                          | docker  | **A**                       | rw tsdb; egress: scrape targets only (tailscale CIDR); loki: ingest loopback                                                                                                                                                                                   |
| **trilium / homepage / searx / sftpgo / transmission** | systemd | **A** (boring-tier default) | per-service state dir; sftpgo/scraping-tier: egress as needed (searx _needs_ internet — pin to engine CIDRs? no; allow 443)                                                                                                                                    |
| **xmpp (prosody)**                                     | systemd | **A**                       | federation out: 5269 only                                                                                                                                                                                                                                      |
| **firefly-iii**                                        | systemd | **A**                       | php-fpm + nginx already private-ish; egress: postgres only                                                                                                                                                                                                     |
| **mosquitto** (akos01)                                 | systemd | **A** + **auth (audit #2)** | rw data; egress none; 1883 requires password (anon currently on)                                                                                                                                                                                               |
| **vaultwarden** (akos01)                               | docker  | **A**                       | rw state; **no internet egress at all** (self-hosted pw vault needs none)                                                                                                                                                                                      |
| **step-ca / traefik / tailscale / dnsmasq**            | systemd | **A**                       | infra-tier; traefik egress: loopback + upstream resolver                                                                                                                                                                                                       |

#### GPU path (why these never cross to B)

CDI = host→container boundary mechanism, not a VM boundary. MicroVM GPU passthrough
is PCIe-level pain on this hardware for no gain, because **LiteLLM is already the
firewall between code and silicon**: agent VMs reach GPU models only via litellm's
HTTP API, never a device. So: ollama/vllm/immich-ML stay host-side (Tier A), the
agents go to VMs, nobody needs a GPU inside a VM. `MODULES.virtualisation.podman`
(rootless, already in the repo) + `nixos-hardware`'s CDI setup covers `vllm`/
`librechat` image runs when the docker→podman swap happens.

### 2.3 microVM workstream (Tier B) — what's actually involved

`microvm.nix` is not an input yet:

```nix
inputs.microvm.url = "github:microvm/microvm-nix";
# host:
microvm.host.enable = true;
# per micro: separate config via MODULES.* reuse — the whole point of the repo layout
```

- Reuses `MODULES.*` unchanged (that was the architectural bet from the start) —
  `vm-agents` config = `profiles/global` + `services/litellm`-client + `services/n8n`
  pointed at a VM-local postgres? No — **postgres stays on hp**: agents connect over
  tailscale with scram creds. VM-local DBs would break the §4 dump layering.
- RAM budget: `vm-agents` balloon target 3 G; on a 21 G box with 17 G already used,
  **B is only affordable if ollama's models or the docker containers get trimmed** —
  this is the real cost of Tier B, say it plainly.
- Networking: host-side `microvm.kvmd` bridge + tailscale inside the VM (each VM gets
  a tailscale auth key secret, like hosts do).
- Rollout order: (1) n8n-sandbox alone → proof the pipeline; (2) n8n + hermes-agents
  together; (3) reassess.
- Deploy-rs: VM _configurations_ deploy as normal flake outputs; the host needs
  `microvm.host.vms = { vm-agents = ...; }` pointing at the built runnables —
  one `deploy -s .#hp .#vm-agents`.

### 2.4 What Tier A _doesn't_ buy, priced honestly

Same-kernel is same-kernel: a 6.18 kernel 0-day gets hp from any Tier-A jail. Tier B
covers that for exactly the services where it's worth RAM. Everything else: kernel
updates are your mitigation, and the jail + limits + egress layers mean a kernel bug
still can't silently read vaultwarden.

### 2.5 The model-file trap (one-line rule)

A GGUF downloaded from an untrusted source is adversarial input parsed by C++
(ollama/vllm). Jail the parser: ollama's `MemoryMax`/`TasksMax` + its own user is
Tier A; the _only_ rule: no model files from the internet that aren't from the
official registries, enforced by the same auditd rule set watching `openat` in the
model dir.

---

## 3. Layer 3 — syscall-level inspection (auditd)

### 3.1 Option set, re-verified this session

| option                         | status on nixpkgs 26.05                                                                                                                 | verdict                                                                                                             |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **auditd**                     | modules present (`security.audit.rules`, `security.auditd.enable`), kernel audit already compiled (hp's `lsm=` line doesn't need audit) | **use this**                                                                                                        |
| Falco                          | **removed from nixpkgs** (only `falcoctl` ships)                                                                                        | would mean vendoring a flake input + its eBPF probes — not worth it when auditd covers the fork/shell/connect class |
| Tetragon                       | not packaged                                                                                                                            | same objection, more so                                                                                             |
| gVisor (packaged)              | syscall _filtering_, not inspection                                                                                                     | it's a containment tool, not a detective — belongs in §2's alt column, not here                                     |
| eBPF by hand (bpftrace/bcc)    | present                                                                                                                                 | great for ad-hoc ("who is forking 4000/s right now"), not a standing watcher                                        |
| auditd _without_ Falco's rules | nixpkgs ships none — rules below are the hand-written version                                                                           |                                                                                                                     |

### 3.2 Rules — three groups, all cheap

```nix
security.audit.enable = true;
security.auditd.enable = true;
security.audit.rules = [
  "-e 1" "-b 8192" "-f 1"   # enable, backlog, panic-on-failure (audit must never silently stop)

  # 1. process execution — the fork-bomb / webshell signal. Per-service-user:
  "-a always,exit -F arch=b64 -S execve -F euid=1000 -F key=svc-exec-synapse"
  # (generate this list from the users table: postgres, litellm, n8n, ollama, ...)
  # auditd logs EVERY execve by those uids. litellm's legit process tree is static —
  # an execve it didn't do yesterday is the alert.

  # 2. the "it's over" set (rare → zero noise):
  "-a always,exit -F arch=b64 -S mount -S umount2 -S pivot_root -k mount"
  "-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k modules"
  "-a always,exit -F arch=b64 -S ptrace -k ptrace"
  "-a exit,always -F arch=b64 -S bpf -S kexec_load -k kernel"
  "-w /etc/shadow -p wa -k secret-access"
  "-w /run/secrets/ -p rwxa -k sops-access"
  "-w /var/lib/postgresql/ -p wa -k pg-data"          # who touched the DB files?
  "-w /var/lib/private/ -p rwxa -k jail-break"        # ProtectSystem jail dirs

  # 3. network connect()s by code-running uids only (fork/exec already covers #1 for others):
  "-a always,exit -F arch=b64 -S connect -F euid=1003 -F auid!=unset -k n8n-connect"
];
```

### 3.3 Ship to Loki (detection is worthless if it lives only in `ausearch`)

`auditd` writes `/var/log/audit/audit.log`; `promtail` (already your shipper) tails it,
pipeline: keep `svc-exec-*`, `mount`, `modules`, `secret-access`, `sops-access`, and
rate-limit the exec key (a python import storm isn't news — a `sh -c` under litellm is).
Grafana alerts: any `key=svc-exec-*` whose `exe=` is outside the service's known-binary
allowlist (seed the allowlist from one clean week of data); any hit on `mount/modules/
ptrace/sops-access` is page-worthy.

### 3.4 egress LOG — zero new daemons, day one

Add to the egress chains (hermes-agent pattern generalized): `-A <svc>-egress -j LOG
--log-prefix "egress-deny-<svc>: " -m limit --limit 6/min` before the REJECT. Every
blocked lateral move is then a journald line → already in Loki → already grafana-capable.
This is the highest-signal-per-effort detector in the whole plan.

### 3.5 Optional, later

`RestrictAddressFamilies`, `PrivatePIDs=`, `SystemCallFilter=@system-service` (the
jail module sets these — that's _prevention_ layered on top of auditd's _detection_).
`fapolicyd` exists in nixpkgs; skip: store churn makes policy authoring on NixOS
miserable.

---

## 4. Layer 4 — ZFS snapshot/backup plan (consolidated)

### 4.1 Three copies of anything that matters

| copy | host      | what                                                         | dies with                          |
| ---- | --------- | ------------------------------------------------------------ | ---------------------------------- |
| L1   | hp        | live data + `auto_*` local snapshots                         | hp's disk                          |
| L2   | akos01    | hourly replica of hp's `zroot/persist/hp` + its own `auto_*` | home network _and_ airlab together |
| L3   | inside L2 | `pg_dumpall` .sql.gz ×30 days + (TODO) offline sops key      | L2 only                            |

Mechanism everywhere: **sanoid + syncoid** (`modules/system/backup.nix`, wired for all
three hosts, full `nix build` passes, **undeployed**). znapzend is on the retirement
path: §4.4. The stale August `syncoid_*` snapshot set was destroyed 2026-10-24 (~60 G
freed; 241 G free). If a `syncoid_*` snapshot ever reappears, something is
misconfigured — `--no-sync-snap` is a hard invariant.

### 4.2 Schedules (sanoid, recursive)

| host    | dataset                                    | hourly | daily | weekly |
| ------- | ------------------------------------------ | ------ | ----- | ------ |
| hp      | `zroot/root`                               | 24     | 14    | 8      |
| hp      | `zroot/persist/hp`                         | 24     | 14    | 8      |
| hp      | `zroot/persist/legion5`                    | 24     | 14    | 8      |
| akos01  | `zroot/root`                               | 24     | 14    | 8      |
| akos01  | `zroot/persist/hp` (prune-only, mirror hp) | 24     | 14    | 8      |
| legion5 | `zroot/root` + its homes                   | 12     | 7     | 4      |

Timer layout on hp: `:00` sanoid → `:20` syncoid-push → `daily ~00:00` pg_dumpall
(00:05 snap catches the fresh dump, 00:20 ships it). Excluded on purpose: `zroot/nix`
(rebuildable), `/var/lib/docker` 64 G and `/var/lib/transmission` 49 G (local snaps
only — never replicated).

### 4.3 Roadmap: carve service state into `zroot/persist/hp`

Everything still under `zroot/root` is snapshot-local but **not on akos01** until it
gets its own dataset under `persist/hp` (then it joins sanoid + syncoid scope
automatically). In value order: (1) postgresql, (2) matrix (synapse/MAS/mautrix —
media & pickle state isn't dumpable), (3) **immich — the least replaceable bytes on
this network**, (4) nextcloud/trilium/librechat/n8n/omniroute/hermes/paseo/notes,
(5) prometheus/loki (skip if capacity matters). Recipe per service: stop unit →
`zfs create -o mountpoint=… zroot/persist/hp/<svc>` → rsync → start → verify → rm old.

define the volumes on the host using disco and create them manually, make sure that the newly created datasets exactly match the disco config, otherwise i will not be able to reboot
only define the volumes for the host itsel eg on hp only persist/hp needs to be defined, even if it has the backups from akos01

### 4.4 znapzend retirement (you chose syncoid)

hp currently _receives_ legion5's laptop push via znapzend (74 snaps, live). Plan:
give `backup.receive` on hp the `zroot/persist/legion5` scope + prune-only sanoid,
legion5 switches its `MODULES.system.backup.push` to hp (the key already works —
syncoid key is in `profiles/global.nix`'s authorizedKeys; it needs its `from=` scope
widened to include the laptop, plus a laptop-side keypair in sops). After one clean
weekly cycle: `MODULES.system.znapzend.enable = false` on both hosts, znapzend snaps
age out. Keeps one naming scheme everywhere; the adoption problem is moot with the
strays gone.

no i chose znapzend, i already use it it can be easily configured through nix

### 4.5 Keys — the gap snapshots don't cover

`/var/lib/sops-nix/key.txt` is **not** a recipient of `secrets.yaml` (decryption is
each host's SSH host key, ssh-to-age'd in `.sops.yaml`). Lose hp + akos01 + both
laptops simultaneously ⇒ secrets unrecoverable; step-ca root key lives in an
off-repo dir nobody has verified. TODO (offline): one age backup key as recipient,
`sops updatekeys`, private half in password manager; verify the `pki/` backup restores.

### 4.6 Restore cheat-sheet

- file: `zfs clone …@auto_… /mnt/tmp` · service: `zfs rollback` · DB logic: newest
  `pg_dumpall-*.sql.gz` → `psql -f` · akos01-only recovery: clone received snaps.
- Verify after each deploy: sanoid took snaps → syncoid service starts → snaps visible
  on akos01 → dump dir fresh. Grafana alert when the zfs-exporter's snapshot set stops
  gaining `auto_` members — **freshness is the only signal that matters**.

### 4.7 Implementation status 2026-10-24 — znapzend it is (user decision above wins)

`modules/system/backup.nix` / sanoid never existed in this tree; every sanoid/syncoid
sentence above is superseded. Shipped instead: **`modules/system/znapzend.nix`**
(`MODULES.system.znapzend.{enable,jobs,pgDumpDir,sshKeySecret}`), legion5's productive
config promoted to the module and all three hosts wired:

| §4.2 row            | plan actually written              | where                     |
| ------------------- | ---------------------------------- | ------------------------- |
| 24/14/8 servers     | `1d=>1h,2w=>1d,8w=>1w`             | hp (root, persist/hp, persist/legion5-local), akos01 (root) |
| 12/7/4 laptop       | `12h=>1h,7d=>1d,4w=>1w`            | legion5 (root, persist/legion5 + push→hp) |
| hp→akos01 L2 push   | destination on `zroot/persist/hp`  | `destinations.akos01` row; akos01 runs NO mirror schedule (source prunes the destination; §4.2's "prune-only" = absence, which is what znapzend wants) |
| pg_dumpall 00:05    | timer `znapzend-pg-dump`           | hp `/var/lib/pgdump` (= dataset `zroot/persist/hp/dump`, rides the push) + akos01 (dir on root, covered by L1); gz, hostname-dated, 8w prune |

Trust model: hp pushes to akos01 as root with a dedicated ed25519 key (private half:
sops `znapzend/ssh_key_b64`, base64'd PEM; module decodes to `/etc/ssh/znapzend/id_ed25519`
via `znapzend-ssh-key.service`); the public half sits on akos01's root authorized_keys
**locked** to `command="…/znapzend-shell"` (allowlist of `zfs recv|create|destroy|list|get|set|
mount|umount|version`, no-pty/no-forwarding). Client pinning via a root-`Match exec` block
appended to `/etc/ssh/ssh_config` (IdentityFile only for uid 0, BatchMode; accept-new so the
daemon's first connect pins akos01's host key — the one-time bootstrap). legion5→hp keeps the
pre-existing laptop trust untouched. Freshness signal: `logTo=/dev/stderr` → journald →
Alloy→Loki; query `{unit="znapzend"}` stopping is the alert, plus the §4.6 Grafana follow-up.

**Manual steps (one-time, in order):**
1. After deploying hp, create the new dump dataset and check the declared chain matches
   (per §4.3 rule: datasets must exactly match disko before any reboot):
   `zfs create -o mountpoint=/var/lib/pgdump zroot/persist/hp/dump` and
   `zfs get mountpoint zroot/persist zroot/persist/hp` → expect `/persist`, `/persist/hp`
   (disko now declares all three parents explicitly; sftpgo row unchanged).
2. Deploy akos01 first (authorized_keys must accept hp's key before hp's first push),
   then hp. On hp's first znapzend start, the import probe may spend ≤90 s against
   akos01 — TimeoutStartSec 180 covers it.
3. Verify after first cycle: `znapzendzetup list` on both servers; next morning:
   `zfs list -r -t snapshot -o name,creation | grep znapzend | head` on akos01 shows
   received snaps of hp's persist/hp, and `/var/lib/pgdump/hp-*.sql.gz` exists.
4. §4.5 key-backlog TODO remains open (unrelated to znapzend).

---

## 5. Security audit remediation (from `SECURITY-AUDIT-2026-10-24.md`)

---

## 5. Security audit remediation (from `SECURITY-AUDIT-2026-10-24.md`)

The containment layers make findings #2/#3/#5 _less fatal_, but fix them anyway:

1. **Shared yescrypt root/akos hash in repo** → `mkForce ""` password or sops secret; rotate.
2. **mosquitto anonymous + open fw (akos01)** → password file via sops, `allow_anonymous false`, firewall to tailscale/LAN only.
3. **immich ML worker on `0.0.0.0:3003`** → `IMMICH_HOST=127.0.0.1`, traefik/tailscale only.
4. **No disk encryption (legion5 laptop!)** → `boot.initrd.systemd` + TPM2/`clevis`-style unlock or passphrase; plan: `MODULES.system.luks` module, laptop first.
5. **World-readable litellm master key (`homepage.nix:209`)** → 0600, group-only; jail's `InaccessiblePaths` covers neighbours meanwhile.
6. **`electron-39.8.10` insecure + `allowBroken=true`** → pin `permittedInsecurePackages` to the one package, `allowBroken=false`.
7. **X11Forwarding + agent forwarding on sshd** → both off (builder access over tailscale only).
8. **omniroute plaintext password** → sops secret.
9. **registration defaults unpinned** → `services.xmpp.registerAtRoot = false` etc. where applicable.
10. **Postgres socket `trust`** → §2.1 prereq, scram + per-service roles.
11. **PHP RCE (firefly-iii php-fpm)** — _fixed 2026-10-24_. Two critical (CVSS 9.2,
    unauth RCE) advisories published Oct 21: `CVE-2026-109618` / GHSA-w8hw-w9fx-j79w
    (OOM corruption, triggerable with crafted multipart requests) and
    `CVE-2026-109619` / GHSA-6wmf-4rv5-p3rp (stale global state; validated FPM
    exploit path via session upload progress). Only PHP consumer on any host is
    firefly-iii (nginx+php-fpm 8.4.26 from the Oct-12 lock — vulnerable; SAPI FPM is
    susceptible per source analysis). Fix: nixpkgs bump → php **8.5.12** deployed and
    verified running (`/proc/<php-fpm>/exe`). Belt-and-braces kept in
    `firefly-iii.nix`: `session.upload_progress.enabled = 0` (the FPM consumer path,
    no feature loss) + `pm.max_requests = 10` (breaks the same-worker
    producer→consumer chain). Standing rule: the advisory says config mitigation is
    never complete — the channel pin's age is now the metric; watch
    `php`-CVE-driven rebuilds like any other patch level.

---

## 6. Implementation order

| #   | step                                                                                                                                                       | depends             |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| 0   | deploy the working tree: backups (akos01 first, then hp/legion5)                                                                                           | —                   |
| 1   | postgres scram + per-service DB users (§2.1)                                                                                                               | —                   |
| 2   | `modules/security/jail.nix` (the `MODULES.security.jail` factoring of hermes-agent: rwPaths / egress / `PrivatePIDs` / `RestrictIFaces`) + §3.4 egress LOG | 1                   |
| 3   | `modules/system/limits.nix` + `LIMITS` table (§1)                                                                                                          | — (parallel with 2) |
| 4   | auditd rules + promtail tail + Grafana alerts (§3)                                                                                                         | 2 (same users list) |
| 5   | remediation items §5.1–5.9 (small diffs, any order)                                                                                                        | —                   |
| 6   | `microvm` input + `vm-agents` prototype (n8n-sandbox only, prove pipeline)                                                                                 | 0–3                 |
| 7   | GPU path: docker→rootless podman+CDI for `vllm`/`librechat`; §1.5 slice meanwhile                                                                          | —                   |
| 8   | ~~znapzend→syncoid unification (§4.4)~~ → **inverted 2026-10-24**: znapzend won, see §4.7 | done                |
| 9   | dataset carve-outs as services need them (§4.3) — persist chain + dump declared in hp disko, per-service carve-outs open | 0                   |

## 7. Decisions I'd like back

- **RAM reality check**: `vm-agents` (3 G) only fits if something else shrinks — what goes: fewer concurrent ollama models, the docker stack, or do Tier-B only for n8n-sandbox?
- Tier A first for **n8n** (jail) with sandbox-only in a VM, or both to VM from day one?
- oomd on/off after week one (§1.4).
- LUKS scope: legion5 only, or hp too (hp is a server behind a locked door; laptop is in a backpack).

i think ram is not an issue, i have quite a bit of ram available, i would prefer to run everything in microvm with firecracker

you could also add some sort of deep packet inspection in between each service so that i know how they are communicating with each other and can block any unwanted traffic, this would be especially useful for the services that are running in microvm and have access to the network, also configure some sort of an appilcation based firewall for the services so that they can only access things or get accessed by things that are actually needed for proper operation

### 7.1 Implementation status 2026-10-24 — `modules/security/service-graph.nix`

The two answers to the ask above, one module:

- **Application-based firewall (east-west graph)**: an iptables chain (`SG-INPUT`, jumped
  from INPUT position 1, SYN-scoped) rendered from a declarative edge table — humans
  (ssh/https/dns from the tailnet), Prometheus hub→exporters (peers derived from the
  flake's own `nixosConfigurations`, so adding a host needs no edit), Loki ingest, Coroot
  UI+OTLP, Syncthing BEP (peer /32s), step-ca, plus per-host `allow` rows. Unmatched
  SYN = rate-limited `sg-seen:` LOG; `enforce = true` flips the tail to REJECT (ship in
  log-only, flip per host once a week of logs is explainable). `networking.nftables.enable`
  is deliberately NOT used: it blacklists `ip_tables` and would kill every jail egress
  chain. Enabled log-only on hp + akos01; loopback service↔service stays in the jail
  egress chains (that half of the graph shipped with §3).
- **Passive DPI**: Suricata 8 on hp's tailscale0 (`af-packet`, never in the path —
  detection only). Its pass-list is GENERATED from the same edge table, so the IDS and
  the filter cannot drift apart; anything undeclared that completes a SYN alerts
  (`SG-DRIFT`), EVE JSON → journald (`suricata-eve-tail`) → Loki. No remote rulesets:
  the local edge rules are the whole policy, fully auditable in-git.

`MODULES.security.jails.<name>.backend = "microvm"` still trips its eval-time refusal
until a row of the same name exists in `MODULES.system.microvmHost.vms` (hp's list today:
`vm-agents`); flip instructions are the comment block atop `modules/vm/microvm-host.nix`.

### 7.2 microVM pipeline (firecracker) — prototype shipped 2026-10-24

Per the RAM/firecracker decisions above. `microvm-nix/microvm.nix` is a locked flake input
(its nixpkgs follows ours, one package set for host+guests). Shipped:

- `hosts/vms/vm-agents.nix` — prototype guest (1 G / 2 vCPU, firecracker, tap
  `mv-vm-agents-0`, static 10.99.0.11 gw 10.99.0.1, serial getty, sshd with the laptop
  key, tailscale client as its own tailnet node). Builds: `nix build
  .#microvmConfigurations.vm-agents.config.system.build.toplevel`.
- `modules/vm/microvm-host.nix` — `MODULES.system.microvmHost.{enable,vms}`; imports the
  microvm host module, creates bridge `mvbr0` (10.99.0.1/24, `mv-*` taps auto-enslaved by
  name match), NAT + default-deny-forward for the guest subnet, per-VM units from the
  flake's `microvmConfigurations` via `evaluatedConfig`, `restartIfChanged` on activation.
  Enabled on hp with `vms = [ "vm-agents" ]` — the runner drv
  (`microvm-firecracker-vm-agents.drv`) is confirmed in the host config.
- Guests live in a separate flake attrset, NOT `nixosConfigurations` (deploy-rs iterates
  that set; VMs must never be ssh-activated from the host list).

Manual steps for the prototype to go live: deploy hp → `systemctl start
microvm@vm-agents` (or autostart) → `microvm console vm-agents` → `tailscale up
--authkey=…` (ephemeral key from the tailnet console, ACL tag e.g. `vm`) → from any host
`ssh root@<its-tailnet-ip>`. Follow-ups before any real service flips: sharedDir + §4.3
dataset for writable state, coroot-node-agent inside the guest (nixpkgs package exists;
flag wiring open), SERVICE_GRAPH rows for its tailnet IP, LIMITS rows counting VM memory
against the 18 G budget.

