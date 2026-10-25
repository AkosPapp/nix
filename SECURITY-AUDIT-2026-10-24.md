# Security audit — `~/nix` (NixOS flake)

Date: 2026-10-24
Scope: all hosts, modules, profiles, users, sops/pki config, git history.

Overall posture is good (sops-nix everywhere, key-only SSH, loopback-pinned backends,
tailnet-only Traefik, genuinely hardened hermes-agent sandbox).

## HIGH

### 1. Shared, committed password hash

The identical yescrypt hash appears as root on hp (`hosts/hp/hardware-configuration.nix:42`),
root on legion5 (`hosts/legion5/hardware-configuration.nix:108`) *and* as `akos`
(`users/akos.nix:53`).

- root and the daily-driver user share one password
- the hash is in git
- Nix makes every hash world-readable in the `/nix/store` for any local process/user

Console root login on servers is only as strong as a password that also authenticates a
workstation account.

**Fix:** sops `hashedPasswordFile` (or `forcePasswordFile`) with distinct hashes; rotate the
akos password.

### 2. Mosquitto: anonymous + open firewall + full ACL on 0.0.0.0

`modules/services/mosquitto.nix` sets `allow_anonymous = true` and `pattern readwrite #`,
plus `networking.firewall.allowedTCPPorts` on *all* interfaces, enabled on akos01
(`hosts/akos01/default.nix:109`). Anyone routable to akos01:1883 gets a read/write MQTT
broker.

Same pattern for FastDDS (`hosts/akos01/default.nix:108`) — unauthenticated by design.

**Fix:** scope both to `firewall.interfaces.tailscale0` or add auth.

### 3. Immich ML worker unauthenticated on the LAN

`modules/services/immich.nix:164` forces `IMMICH_HOST=0.0.0.0` and line 180 opens port 3003
on all interfaces (enabled on hp). The worker has no auth; a LAN peer can feed it arbitrary
jobs / read its outputs.

Other modules in this repo (ollama:194, vllm:526) correctly use
`firewall.interfaces.tailscale0` — this one should too.

### 4. No disk encryption anywhere

No LUKS/`canEncrypt` in any disko config; akos01's swap is plaintext
(`hosts/akos01/default.nix:282`). legion5 is a laptop.

A stolen laptop exposes sops age keys (`/var/lib/sops-nix/key.txt`), the step-ca
intermediate key, Syncthing secrets, Signal/WhatsApp bridge credentials — i.e. the whole
fleet, since all hosts share one `secrets.yaml` recipient set.

## MEDIUM

### 5. World-readable LiteLLM master key

`modules/services/homepage.nix:209-211` (`mode = "0444"`; also 105, 191). The admin key
doubles as the LiteLLM UI login, so any local user on hp is a gateway admin. The comment
acknowledges the tradeoff; minting a read-only virtual key is cheap.

hermes-agent already sandboxes against exactly this (`hermes-agent.nix:39`), which confirms
the threat is real for other units.

### 6. `builder` is `trusted-users` + `wheel` with an SSH key

`modules/nix/builders/build-host.nix:40,49`. Nix trusted-users ⇒ trivial root (arbitrary
derivation). If legion5's key (`root@legion5`) leaks, the build host is root-owned remotely,
and deploy pulls closure into akos01/hp (`copy_to`).

**Fix:** drop `@wheel`/`builder` from `trusted-users` (keep `@nixbld`).

### 7. `allowBroken = true` + `permittedInsecurePackages`

`profiles/global.nix:100`, `users/akos.nix:17`, `flake.nix:52`. Knowingly shipping a
vulnerable pinned Electron (`electron-39.8.10`) and any eval-broken package globally.

**Fix:** narrow `permittedInsecurePackages`, drop global `allowBroken`.

### 8. X11 + agent forwarding on sshd

`modules/networking/sshd.nix:17-22`: `X11Forwarding` plus `sshAgentAuth` means any
compromised remote X client can use the forwarded agent (which can unlock everything).

Both look present for convenience on the laptop; on servers (hp/akos01) disable, or at least
`X11UseLocalhost` + client-side `ForwardAgent no` defaults.

### 9. omniroute initial password in plaintext, outside sops

`hosts/hp/default.nix:363` (`/var/lib/omniroute/secrets.env`, INITIAL_PASSWORD). Verify it
was consumed/rotated at first login; the file persisting on disk is a leak of the dashboard
credential.

### 10. Registration defaults not pinned

- immich server (`immich.nix:131-135`) never sets `settings.server.signUpDisabled`
- Firefly III registration is open by default in newer versions
  (`hars` shows a public `/firefly/register` visit via the Funnel on 2026-09-02)

Tailnet/Funnel scoping is the only thing preventing self-signup on finance/photo apps —
assert it declaratively.

## LOW / hygiene

- **`hars`** — a committed Chrome HAR of `hp.tail546fb.ts.net/firefly/register`. No auth
  headers found, but it's recon data (URL layout, CSP, internal naming) that doesn't belong
  in the config repo.
- **`mcp.json`** gives an agent a filesystem MCP rooted at the repo — which currently contains
  decrypted-able material paths + git identity.
- **`flake.nix` is now `0644 root:hermes`** while the rest of the repo is `0600` — looks like
  a stray `sudo` edit; `chmod 600`, and consider chowning back.
- **`auto-install.sh`** rsyncs the whole repo (incl. encrypted secrets + tmp host keys) to
  `/tmp/nix` on the target and installs with a root password (`nixos-install` without
  `--no-root-passwd` on the second run, line ~44).
- **No fail2ban** on internet-adjacent hosts; mitigated by key-only SSH, but Funnel-side brute
  force against dashboard logins (hermes basic auth, omniroute, n8n) has no rate limit.
- **`programs.ssh.forwardX11` + mosh + nmap/netcat/sshpass/wireshark/burpsuite** on the laptop
  widen its post-compromise value; fine as a pentester's box, just be aware.

## What's notably good

- Per-uid iptables egress jail for the hermes agent with path-triggered port sync
  (`hermes-agent.nix:462`)
- Near-complete systemd sandboxing on agent units
- Loopback-only backends with an explicit central `PORTS` registry + collision assertions
- step-ca loopback-only with zone-scoped cert policy
- `users.mutableUsers = false`
- sops with per-service `0400` owners and template/placeholder usage
- Assertions that refuse to boot a public LiteLLM without a master key (`litellm.nix:695`)
- Offline root CA by design (`pki/generate.sh`)

## Suggested priority order

1 → 3 → 2 → 4 → 5/6.
