# AGENTS.md

Rules for AI agents (and humans) working in this NixOS fleet repo. Read this
before changing anything under `hosts/`, `users/`, `modules/`, or `profiles/`.

## The repo in one breath

`flake.nix` auto-imports every `*.nix` under `modules/` (plus `profiles/` and
`users/`) into every `nixosConfiguration`, and wires each `hosts/<name>/`
directory as the host's own module. `users/<name>.nix` are opt-in user modules
(enabled via `USERS.<name>.enable`). Everything under `modules/` is therefore
*always available* - a host never needs an `imports` line to use one, and nothing
outside `hosts/` may reference a specific host name.

The machines are `hp`, `akos01` and `legion5`; `iso` is a buildable installer
config, not a node. Firecracker guests (`hosts/vms/`) live in
`microvmConfigurations`, **not** in `nixosConfigurations` - deploy-rs iterates
the latter and must never ssh-activate a VM; guests deliberately see
`nixosConfigurations = {}`.

## Rule 1 - host files are service lists, not implementations

`hosts/<name>/default.nix` may contain **only**:

1. `enable` flips for modules (`MODULES.<...>.enable = true;`), optionally
   with the host's values for that module's options;
2. genuinely host-specific facts: its Tailscale IP, disk layout, hardware
   tweaks, which datasets it replicates, its Syncthing device ID, secrets'
   sops keys, and dated incident notes explaining *this host's* choices;
3. `imports` for its own `hardware-configuration.nix` / `disko` pieces.

Everything else - shell scripts, systemd units, tmpfiles rules, package
lists, resolver configs, provider catalogues, forced-command ssh wrappers -
belongs in its own module under `modules/`, expressed as options with
defaults so a host that wants stock behavior writes one `enable` line and a
host with a twist overrides a named option.

Litmus test: *if a second host could ever want the same block, or the block
contains logic rather than values, it is a module, not host config.*

Recent refactors that established this (their shapes are the templates to
follow, not to re-litigate):

- `modules/networking/dns/split-dns.nix` - the dnsmasq dynamic include, the
  `ip monitor` watcher unit, the timer, the tailscale flags and the tmpfiles
  entry live here; `MODULES.networking.dns.splitDns` options are
  `enable`, `publicServers`, `acceptRoutes`, `advertiseExitNode`, and
  `labForward.{enable,zone,server,interface,addressPrefix}` (`interface =
  null` means a static `/airlab` forward; an `interface` gates the forward
  on that interface holding an address from `addressPrefix`).
- `modules/services/model-catalog.nix` - the fleet's single model fact
  table (`MODULES.services.modelCatalog.models`, keyed by LiteLLM name, with
  a `lookup` helper). opencode, paseo, paseo-machine and hermes-agent all
  take their context/output lengths, thinking levels and costs from it by
  default.
- `modules/services/opencode.nix` - renders its default provider catalogue
  from the model catalog; a host/user that just wants the standard setup
  sets `enable` + model choices, nothing else.
- `modules/services/hermes-agent.nix` - owns the agent tool set
  (`ocrLanguages`, `extraPackages`), the notes-share wiring
  (`notes.{enable,shareDir,shareOwner}`: tmpfiles modes, `BindPaths`, the
  `hermes-notes-edit` escalation tool), and the `modelContextLength` pin
  (defaults from the catalog).
- `modules/system/znapzend.nix` - owns the push-destination side
  (`acceptPush.{enable,datasetPrefix,authorizedKey}` composes the
  forced-command `authorized_keys` line) and the pg-dump dataset creation
  (`pgDumpDataset`).
- `modules/security/service-graph.nix` - the fleet's single tailnet edge
  table. The nft/iptables allow-jails and the Suricata tap's pass-list are
  both rendered from it, and it derives peer sources (Prometheus scrapers,
  the immich server <-> ML-worker dial chain) from the `nixosConfigurations`
  specialArgs. **A new service that accepts or dials tailnet TCP must add
  its edge there - in both roles, since each host's tap also sees our own
  outbound SYNs - or Suricata fires `SG-DRIFT` on every connection of it.**

## Rule 2 - no duplicated blocks, ever

Identical (or near-identical) code repeated across hosts/users is a bug:
the next fix lands in one copy and silently misses the others. When you see
two hosts repeat a block:

1. Move it into the module that owns that concern (create the module under
   the right `modules/<area>/` if it does not exist yet).
2. Expose whatever actually differs between hosts as *options with
   defaults matching the common case*, so the majority of hosts stay at one
   `enable` line.
3. Hosts/users then restate **values** (IPs, dataset names, which model),
   never **scripts, units, option-rendering logic, or model numbers**.

Concrete instances of the rule in this repo - extend rather than repeat
them:

- Model numbers (`contextLength`, `outputLength`, thinking levels/effort
  kwargs, costs) exist **only** in `modules/services/model-catalog.nix`.
  Consumers default from it via `MODULES.services.modelCatalog.lookup`;
  hosts/users only name the model.
- Per-unit resource caps exist **only** in `modules/system/limits.nix`
  (`config.LIMITS` rows, `tiny`/`boring` tiers, dated sizing notes). Units
  get no `MemoryMax`/`CPUQuota` anywhere else; a host with a twist overlays
  the named row's field.
- The split-DNS scripts existed verbatim on hp, legion5 and akos01 before
  they moved into `modules/networking/dns/split-dns.nix`. Their per-host
  calls (exit-node advertisement, `acceptRoutes`, lab-forward gating on
  `wlo1`) show the option shape.
- The opencode provider/model catalogue lived in `users/akos.nix` *and*
  `hosts/hp/default.nix`; it is now the opencode module's `providers`
  default rendered from the catalog.
- Cross-host facts flow through the flake's `nixosConfigurations`
  specialArgs (hp's Traefik zone list, Syncthing mirror lists, the
  service-graph edge table) instead of being restated per host.

If a block must exist twice for a hard technical reason (e.g. microVM
guests deliberately see `nixosConfigurations = {}` and so spell akos01's
Tailscale IP literally), say so in a comment at the duplication site -
an unexplained duplicate will be assumed fixable and consolidated.

## Fleet namespaces an agent would otherwise miss

- `config.PORTS.<name>` (`modules/networking/ports.nix`) is every service's
  port registry. Modules and hosts interpolate `PORTS.*`; a hardcoded port
  number is a bug (measured 2026-10-27: prometheus scraped cloudflared's
  metrics on the `PORTS` number while cloudflared's own default was a
  different port - the pinning now lives in the generated tunnel config).
- `config.LIMITS.<row>` (`modules/system/limits.nix`): the systemd
  CPU/memory/tasks caps per unit, keyed by predicates over the config.
- sops: one encrypted file, `sops/secrets.yaml` (recipient set in
  `sops/.sops.yaml` = every host's age key). Modules consume it via
  `config.sops.secrets."<key>".path` and `sops.templates`; new keys go in
  via `sops edit` inside `sops/`, never as plaintext anywhere.
- **attrsOf default trap** (verified empirically on nixpkgs 26.05): the
  moment a host defines ANY dotted key under an `attrsOf` option (e.g.
  `LIMITS.ollama.memMax`), the option's *default map* is dropped entirely
  and every row the host did not name vanishes. Fleet-defaulted option maps
  therefore default to `{}` and consumers read them through a field-wise
  merge helper - see the header comments of `modules/system/limits.nix` and
  `modules/security/jail.nix`. Any new option with per-attribute defaults
  must use that pattern.

## Deploy

- deploy-rs config lives in the flake (`deploy.nodes`; `remoteBuild` and a
  10-minute `confirmTimeout` are already set there). Deploy one host from a
  repo checkout with `deploy -s --targets .#<host>`. The long
  `confirmTimeout` is load-bearing: hp's unit-start phase legitimately runs
  past 2 min and the 30 s default rolled back a healthy switch (2026-10-26).
  `iso` is excluded from `deploy.nodes`.
- `make switch` runs `nixos-rebuild switch --flake .# --impure` and then
  **auto-commits**; `make sync` commits and pushes. Agents must not commit
  (see Working conventions), so never use those two targets - `make stage`
  or `git add` only.
- `nix run .#cloudflare-config` is the one-time Cloudflare login/tunnel/DNS
  setup and the sanctioned way to refresh the tunnel's sops secrets.

## Design docs

- `PLAN.md` is the design document module comments cite by section (§2.1
  pg_hba hardening, §3.4 jail egress, §6 microVMs, ...). Read the cited
  section before touching the jail, postgres or microvm modules.
- `SECURITY-AUDIT-2026-10-24.md` is a dated audit whose numbered findings
  several module comments reference; its fixes are already in.

## Working conventions

- Keep the repo's comment style: comments explain *why*, often with a
  dated incident note ("measured on legion5 2026-10-26: ..."). When moving
  code into a module, carry its comments with it.
- Format with `nix fmt .` (alejandra). Never hand-format around it.
- A brand-new file under `modules/` must be `git add`ed (staged, not
  committed) before `nix eval`/`nix build` can see it: the flake's
  `module_files` glob enumerates the *flake source tree*, which for a git
  checkout is what git tracks. An unstaged new module fails with "The option
  ... does not exist" even though the file is on disk.
- Verify with `nix-instantiate --parse <file>` while iterating, and
  evaluate the real configs before finishing:
  `nix eval --raw ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"`
  for every host touched (`hp`, `legion5`, `akos01`, plus `iso` when
  relevant). `nix eval` works offline (inputs are cached).
- Watch for the NixOS "attribute already defined" trap: defining both
  `a.b = x;` and `a = { b = y; };` for the same leaf in one module errors.
- Options need `description`s (or `mkEnableOption` texts) - they surface in
  `nixos-option`/manpages and this repo's modules are written as
  self-documenting APIs for hosts.
- Don't commit or push; the user reviews working-tree changes (staged,
  per the `git add` rule above).
