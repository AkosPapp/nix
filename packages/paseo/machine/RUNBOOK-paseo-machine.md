# Runbook: Paseo harness machine (shell installer path)

Sources: `lib.sh` (primitives), `doctor.sh` (checks), `install.sh` (transaction),
`build-installer.sh` (splices them + `templates/*.in` into the single file the hub
serves at `/install/<token>/<harness>.sh`).

Everything here is rootless: no `sudo`, no writes outside `$HOME` and
`$XDG_RUNTIME_DIR`. The one exception is an explicit opt-in flag
(`--with-system-node`, `--install-linger-sysunit`).

## Layout

| Path | What lives there |
| --- | --- |
| `$XDG_DATA_HOME/paseo/versions/<release-id>/` | one npm prefix per transaction (`cli-<ver>+<harness>-<ver>`) |
| `$XDG_DATA_HOME/paseo/current` | symlink to the live release; the only thing the unit points at |
| `$XDG_DATA_HOME/paseo/bin` | stable shims (`paseo`, `pi`, `paseo-doctor`) that survive a version flip |
| `$XDG_DATA_HOME/paseo/setup` | embedded templates, a stable copy of the installer, the `paseo-doctor` payload |
| `$XDG_STATE_HOME/paseo` | phase file, private npmrc, prefix canary, `previous-release` |
| `$XDG_CONFIG_HOME/paseo/credentials/` | daemon password, model key, hub token - all `0600` |
| `~/.paseo` (`$PASEO_HOME`) | the daemon's own dir (never moved), `install.log` |

`$XDG_*` fall back to their `~/.local/...` defaults. Nothing is installed under
`/usr`, `/nix` or another user's home.

## Verify an install

```bash
paseo-doctor all            # prefix assets native path secrets service terminal
paseo-doctor prefix assets  # just the two groups that explain most failures
paseo-doctor --json all     # machine-readable on stdout; human output on stderr
```

Exit status: `0` green, `1` at least one FAIL, `2` the doctor was invoked
incorrectly (an installer bug, never a broken machine).

If the command is not on `PATH`, the same doctor is reachable through the
installer copy that was kept next to the install:

```bash
bash "$XDG_DATA_HOME/paseo/setup/paseo-install.sh" --doctor all
```

Installer and doctor are always the same file, so they can never be different
versions.

## A full install, in order

`flock` the whole transaction (a second run refuses to interleave and names the
holder) → stop the service **before any package operation** → clean npm staging
leftovers → `npm install` into a **fresh staging prefix** → repair native
bindings once → **doctor the staging tree offline** (a red run removes the staging
tree and changes nothing live) → flip `current` atomically (rollback armed from
this instant, including on `SIGTERM`/terminal hangup) → write shims → prune old
releases → re-emit config + unit (managed files; local edits are backed up, not
clobbered) → start → health gate → pair + register (advisory, never rolls back) →
**full doctor, including an end-to-end terminal test**.

Both package installs happen on every run: there is no "skip when present".
Running inside the daemon being replaced hands the transaction to a transient
`systemd-run --user` unit instead of SIGKILLing itself.

## "terminals fail with ENOENT shell-integration" / "npm prefix looks hollow"

The incident this rewrite exists for. Symptoms: daemon is `active`, `/api/health`
is 200, and every new terminal dies - because npm was killed mid-reify and left a
prefix of a few hundred directories with no `package.json`.

```bash
paseo-doctor prefix assets   # names the missing files
```

Recovery:

1. `systemctl --user stop paseo.service` - the daemon must not be running.
2. `ls -d <prefix>/lib/node_modules/**/.<name>-*` - npm crash leftovers.
3. Either rename a complete tree back and restore
   `<prefix>/bin/paseo -> ../lib/node_modules/@getpaseo/cli/bin/paseo`, or just
4. re-run the installer: it cleans leftovers, installs into a fresh staging
   prefix, doctors it, flips atomically, rolls back on failure.

No-restart note: the daemon re-reads shell-integration assets from disk on every
terminal spawn, so an asset repair takes effect without restarting it - which
matters when the agent you are debugging is a child of the daemon you must not
kill.

## Other failure shapes the doctor checks for

* **Flattened symlink** - `cp -rL`, `docker COPY` without `--link`, `rsync -L`,
  `tar -h` turn `bin/paseo` into a real file. Every static check passes and the
  daemon dies at startup with `ERR_MODULE_NOT_FOUND <prefix>/dist/index.js`. The
  doctor *executes* the shim to catch this class.
* **Native bindings that never built** - npm's `--allow-scripts` allowlist is
  version-fragile, so the doctor `require()`s `node-pty`, `msgpackr-extract` and
  `esbuild` and reports prebuilt vs built-from-source. A missing compiler is only
  a problem on platforms without prebuilds.
* **`node-pty` `spawn-helper` without its executable bit** - the daemon self-heals
  this at spawn; it is only fatal on a read-only tree.
* **Secrets in the wrong place** - a world-readable file containing a secret, or a
  root-owned `~/.paseo` (see below).
* **Duplicate/stale `PATH` in the unit** - the rendered unit gets a deduplicated,
  target-side `PATH`, never the invoking shell's.

Never run the installer as root without `--allow-root`: a root-owned `~/.paseo`
cannot be read by the rootless user unit (its secrets are `0600`), so the install
reports success and the daemon never starts.

## Building the installer

```bash
./build-installer.sh --release cli=0.11.4,pi=1.2.0,opencode=latest \
                     --relay relay.example:443 --hub https://hub.example \
                     --model-base-url https://hub.example/v1 --model-id some-model \
                     --harness pi -o /tmp/pi.sh
```

Two placeholder namespaces, deliberately different:

* `@@PASEO_NAME@@` - **build time**, substituted by this script. An unresolved one
  is a hard build error.
* `%%NAME%%` - **run time**, substituted on the target from `PSI_T_*` by
  `psi_render_template`, which refuses to write a file that still contains a
  placeholder.

The generated script must not carry a credential: `MODEL_KEY`, `HUB_TOKEN` and
`DAEMON_PASSWORD` are not substitutable, and the build fails if anything
secret-shaped appears in the output. Model config is fetched at run time
(`--invite`, or `PASEO_MODEL_API_KEY` in the environment). `--secrets-file` is for
offline/bundle builds only: a `0600` `KEY=value` file of non-secret build tokens.

## Testing a change to these scripts

```bash
bash -n install.sh && bash -n lib.sh && bash -n doctor.sh   # each file parses alone
./build-installer.sh -o /tmp/pi.sh && bash -n /tmp/pi.sh    # and spliced together
bash install.sh --dry-run            # repo copy, no build step needed
bash /tmp/pi.sh --dry-run            # plan + template extraction, writes no state
bash /tmp/pi.sh --doctor all
```

Failure injection (documented, never on by default):

* `--fail-after-copy` - break the staged tree; the doctor must refuse to flip and
  the live install must be untouched.
* `--fail-after-flip` - break the live tree; rollback must restore the previous
  release. Needs two different releases to prove anything (the script says so when
  there is only one).

Both the repo copy and the generated single file are supported: `install.sh` loads
`lib.sh`/`doctor.sh` from beside it when they were not already spliced in, and
unsubstituted build tokens fall back to loud, unroutable dev defaults rather than
being baked into a machine's config.
