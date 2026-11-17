# Per-DEVICE gateway keys for the served installers (owner design 2026-11-15): the
# curl|sh one-liner the owner copies off the homepage /omp page must work on ANY
# device - including ones with no Tailscale - and each device must come up with its
# OWN OmniRoute key, named after its hostname (`omp-<hostname>`), so per-device
# revocation is one dashboard row and usage is per box. A static script cannot bake
# one key per device, so the script asks THIS daemon at install time:
#
#   device --(funnel /install/mint, gated by bootstrap-installers' mintProxy nginx
#   ACL on the X-Mint-Token header)--> nginx --loopback--> this daemon :PORTS.installerMint
#     --> gateway management API /api/keys (reconcile omp-<name>) --> {"key","name","adopted"}
#
# Auth chain: the MINT token (a dedicated sops secret, deliberately NOT the
# enrollment token) is baked into the served script at render time, so whoever can
# fetch the script can mint - bounded by: one key per name (re-runs re-adopt the
# stored value, never double-mint), a per-source-IP hourly cap, a name namespace the
# seed unit never manages, and one journald line per mint. The mint token rides only
# a HEADER (never a URL anyone logs).
# Key VALUES are stored on the gateway under keysDir (0700 this user; the mirror of
# omniroute's root-owned keysDir, which a second service must not write): the row is
# masked by /api/keys lists, so a device re-install gets its SAME key back from the
# file. NOT in znapzend's omniroute dataset - a pool wipe re-mints device keys and
# orphans the old rows (loudly, for dashboard cleanup); the fleet's own nix keys
# under /var/lib/omniroute/keys are unaffected.
#
# Loopback-only binding: the tailscale0 tap never sees it, and the Suricata edge tap
# is bpf-scoped to Traefik's public entry ports, so no service-graph edge is needed
# (the same reasoning as omniroute's own seed unit dialing 127.0.0.1).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.installerMint;

  py = pkgs.writeText "installer-mint.py" ''
    # installer-mint: loopback HTTP mint endpoint for the fleet's curl|sh installers
    # (modules/services/installer-mint.nix). GET/POST /mint?name=<host> (name REQUIRED,
    # must match "<PREFIX>-<hostname>") replies {"key":"sk-...","name":...,"adopted":bool}
    # (compact JSON - the installer parses it with sed when the box has no python3).
    # Loopback-only by binding; the token gate is nginx (bootstrap-installers mintProxy).
    import json
    import os
    import re
    import sys
    import time
    import urllib.error
    import urllib.parse
    import urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    API = os.environ["MINT_API"].rstrip("/")
    TOKEN_FILE = os.environ["MINT_TOKEN_FILE"]
    PREFIX = os.environ["MINT_PREFIX"]
    KEYSDIR = os.environ["MINT_KEYSDIR"]
    MODELS = json.loads(os.environ.get("MINT_MODELS", "null"))
    LIMIT = int(os.environ.get("MINT_RATE", "30"))
    PORT = int(os.environ.get("MINT_PORT", "0"))

    NAME_RE = re.compile(r"^" + re.escape(PREFIX) + r"-[A-Za-z0-9][A-Za-z0-9._-]{0,55}$")

    _buckets = {}


    def log(msg):
        print("installer-mint: " + msg, file=sys.stderr, flush=True)


    def rate_ok(ip):
        # hourly buckets keyed "ip:hour"; prune every other hour's entries.
        hour = int(time.time() // 3600)
        for k in [k for k in _buckets if int(k.rsplit(":", 1)[1]) < hour]:
            del _buckets[k]
        key = "%s:%d" % (ip, hour)
        _buckets[key] = _buckets.get(key, 0) + 1
        return _buckets[key] <= LIMIT


    def mgmt(path, method="GET", body=None):
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            API + path,
            data=data,
            method=method,
            headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode() or "{}")


    def store_path(name):
        # NAME_RE admits [A-Za-z0-9._-] only (no slash, never "."/".." alone) - one
        # path component by construction.
        return os.path.join(KEYSDIR, name)


    def store_write(name, key):
        p = store_path(name)
        tmp = p + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write(key)
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)


    class Handler(BaseHTTPRequestHandler):
        server_version = "installer-mint/1.0"

        def _reply(self, code, obj):
            data = json.dumps(obj, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._handle()

        def do_POST(self):
            self._handle()

        def _handle(self):
            u = urllib.parse.urlparse(self.path)
            if u.path not in ("/mint", "/health"):
                return self._reply(404, {"error": "unknown path"})
            if u.path == "/health":
                return self._reply(200, {"ok": True})
            qs = urllib.parse.parse_qs(u.query)
            name = (qs.get("name") or [""])[0]
            xff = self.headers.get("X-Forwarded-For", "")
            ip = xff.split(",")[0].strip() or self.client_address[0]
            if not NAME_RE.match(name):
                log("reject name=%r from %s (must match %s-<hostname>)" % (name, ip, PREFIX))
                return self._reply(400, {"error": "name must match %s-<hostname> (1-55 chars)" % PREFIX})
            if not rate_ok(ip):
                log("rate limit exceeded for %s" % ip)
                return self._reply(429, {"error": "mint rate limit exceeded"})
            try:
                self._mint(name, ip)
            except urllib.error.HTTPError as e:
                log("mint %s failed: gateway HTTP %d" % (name, e.code))
                self._reply(502, {"error": "gateway rejected the mint (HTTP %d)" % e.code})
            except Exception as e:  # noqa: BLE001 - the device only needs a clear failure
                log("mint %s failed: %r" % (name, e))
                self._reply(502, {"error": "mint failed: %s" % e})

        def _mint(self, name, ip):
            os.makedirs(KEYSDIR, exist_ok=True)
            keys = mgmt("/api/keys")
            rows = sorted(
                [k for k in keys.get("keys", []) if k.get("name") == name],
                key=lambda k: k.get("createdAt") or "",
            )
            spath = store_path(name)
            stored = ""
            if os.path.exists(spath):
                with open(spath) as f:
                    stored = f.read().strip()
            if rows and stored:
                # Re-adopt: row + stored value agree the key exists; hand the SAME
                # value back (idempotent re-install). Several same-named rows: the
                # value belongs to the row we minted first; the rest are orphans by
                # the gateway's own duplicate-name allowance.
                if len(rows) > 1:
                    log("adopt %s: WARNING %d gateway rows are named '%s' - the stored value authenticates the oldest; revoke the rest" % (name, len(rows), name))
                log("adopted %s for %s (stored value)" % (name, ip))
                return self._reply(200, {"key": stored, "name": name, "adopted": True})
            if rows and not stored:
                # Row lives but our copy is gone (keysDir wiped/rolled back): that
                # value was only ever visible in its create response and we do not
                # mint a second same-named key over it - create a FRESH key, which
                # shadows nothing, and name the orphan for hand revocation (the
                # ensure_key doctrine, files-side reversed).
                log("mint %s: gateway row(s) %s live but the stored value is gone - minting a fresh key; revoke row %s on the dashboard unless this was intentional" % (name, [r["id"] for r in rows], rows[0]["id"]))
            body = {"name": name}
            if MODELS is not None:
                body["modelAccessMode"] = "restricted"
                body["allowedModels"] = MODELS
            created = mgmt("/api/keys", method="POST", body=body)
            key = created.get("key") or ""
            if not key.startswith("sk-"):
                raise RuntimeError("gateway create returned no key: %r" % (created,))
            store_write(name, key)
            log("minted %s for %s" % (name, ip))
            self._reply(200, {"key": key, "name": name, "adopted": False})

    def main():
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        log("listening on 127.0.0.1:%d prefix=%s models=%s rate=%d/h/IP keys=%s" % (PORT, PREFIX, MODELS, LIMIT, KEYSDIR))
        srv.serve_forever()

    if __name__ == "__main__":
        main()
  '';
in {
  options.MODULES.services.installerMint = {
    enable = mkEnableOption ''
      the loopback /install/mint daemon: per-device `omp-<hostname>` OmniRoute keys
      for the curl|sh installer (pairs with MODULES.services.bootstrapInstallers.mintProxy,
      which registers the nginx header-ACL'd proxy for it, and
      MODULES.services.omp.bootstrap.mintUrl, which points the script at it)
    '';

    gatewayApiUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString config.PORTS.omniroute}";
      defaultText = lib.literalExpression "this host's OmniRoute (PORTS.omniroute, loopback)";
      description = "The gateway's management API base (loopback on the gateway host).";
    };

    managementTokenSecret = mkOption {
      type = types.str;
      default = "omniroute_management_key";
      description = ''
        sops key holding the write-scope management Access Token (the SAME secret the
        omniroute seed unit authenticates with). Mounted under this module's own
        template name on purpose: sops-nix gives each secret NAME one owner, and
        omniroute already declares that name root-owned - a second owner needs a
        second mount of the same key (the homepage "homepage/grafana_password" twin
        doctrine), and rotation reaches both through restartUnits.
      '';
    };

    keysDir = mkOption {
      type = types.str;
      default = "/var/lib/installer-mint/keys";
      description = "Where minted device-key VALUES are stored (0700 this service) for idempotent re-adopts. NOT omniroute's keysDir (root-owned, nix-declared keys only).";
    };

    namePrefix = mkOption {
      type = types.str;
      default = "omp";
      description = "Required key-name prefix: minted names must match <prefix>-<hostname>. Keeps the dashboard greppable and the namespace split from the nix-managed keys (hermes/homepage/ompBootstrap - a leaked mint token must not be able to mint a row named like one of those) explicit.";
    };

    keyModels = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = ["futurelab/qwen3.8-flash-next"];
      description = ''
        Model ACL for minted device keys: null = the gateway default "all" (the same
        catalogue every harness sees - the owner's "my exact config" ask), a list =
        restricted to exactly those models at CREATE (re-adopts never rescope).
      '';
    };

    ratePerHour = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Max mints per source IP (first X-Forwarded-For entry) per hour. The mint token is the auth; this only caps abuse of a script copy.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.nginx.enable;
        message = "MODULES.services.installerMint only speaks to the bootstrap-installers nginx gate (proxies.mint, which it self-registers) - that endpoint needs services.nginx.";
      }
    ];

    # The gate this daemon hangs behind: the bootstrap-installers header-token proxy
    # (funnel /install/mint, X-Mint-Token ACL rendered from $INSTALL_MINT_TOKEN).
    # Self-registered so a hub flips ONE enable; the tokenVar assertion there then
    # forces the secret to be declared (the hub points it at sops via apiKeys).
    MODULES.services.bootstrapInstallers.proxies.mint = {
      target = "http://127.0.0.1:${toString config.PORTS.installerMint}";
      tokenVar = "INSTALL_MINT_TOKEN";
      header = "x-mint-token";
      upstreamPath = "/mint";
    };

    users.users.installer-mint = {
      isSystemUser = true;
      group = "installer-mint";
    };
    users.groups.installer-mint = {};

    # Same tmpfiles doctrine as the keys tree in omniroute.nix: the dir exists at
    # activation with exact modes, independent of the unit's umask.
    systemd.tmpfiles.rules = [
      "d /var/lib/installer-mint 0750 installer-mint installer-mint - -"
      "d ${cfg.keysDir} 0700 installer-mint installer-mint - -"
    ];

    sops.templates."installer-mint-management-token" = {
      owner = "installer-mint";
      group = "installer-mint";
      mode = "0400";
      content = config.sops.placeholder."${cfg.managementTokenSecret}" + "\n";
      restartUnits = ["installer-mint.service"];
    };
    # Bare {} merge: omniroute already declares the same key; sops-nix merges owner-
    # less declarations with its root mount (the harness modules' pattern).
    sops.secrets.${cfg.managementTokenSecret} = {};

    systemd.services.installer-mint = {
      description = "Per-device installer key mint endpoint (loopback)";
      wantedBy = ["multi-user.target"];
      after = ["network.target" "omniroute.service"];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${py}";
        User = "installer-mint";
        Group = "installer-mint";
        DynamicUser = lib.mkForce false;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        # strict mounts /var read-only; the daemon stores minted VALUES under
        # keysDir (measured on hp 2026-11-15: without this the first mint wrote the
        # gateway row, then failed its own store with EROFS - an orphan row + 502).
        ReadWritePaths = [cfg.keysDir];
        ProtectHome = true;
        Restart = "on-failure";
        RestartSec = "2s";
      };
      environment = {
        MINT_API = cfg.gatewayApiUrl;
        MINT_TOKEN_FILE = config.sops.templates."installer-mint-management-token".path;
        MINT_PREFIX = cfg.namePrefix;
        MINT_KEYSDIR = cfg.keysDir;
        MINT_MODELS = builtins.toJSON cfg.keyModels;
        MINT_RATE = toString cfg.ratePerHour;
        MINT_PORT = toString config.PORTS.installerMint;
      };
    };
  };
}
