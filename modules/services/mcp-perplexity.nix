# Perplexity web-search MCP server on the gateway host (owner ask 2026-11-15): a
# loopback streamable-HTTP MCP daemon exposing `web_search`/`web_fetch`, connected to
# omp EVERYWHERE - nix hosts AND the curl|sh-installed boxes with no Tailscale.
# web_search is FREE by default now (2026-11-15, after OpenRouter's per-model
# billing for perplexity/sonar-pro 402'd every real call twice): backend="searxng"
# asks this host's SearXNG for the ranked web results and hands them straight to the
# calling agent (or, with `answerModel`, synthesises a cited answer on a FREE
# gateway route); backend="sonar" keeps the original paid perplexity/* path.
#
# Why the LLM leg (when enabled) is the gateway (measured 2026-11-15 against the live instance):
# OmniRoute speaks MCP only as a SERVER (embedded stdio/SSE/streamable, dashboard
# proxies /api/mcp/*); it has NO external-MCP-client registry - /api/mcp{,-servers,
# -settings}, /api/integrations, /api/tools all 404 and its docs list only
# OMNIROUTE_MCP_* flags for its OWN server. So "connect omniroute to it" inverts to
# the supported shape: OmniRoute already fronts `openrouter/perplexity/sonar-pro`
# (verified live: current-events answers with real citations), and THIS daemon calls
# that route with a nix-minted gateway key (MODULES.services.omniroute.keys.
# mcpPerplexity, audit #7). One credential everywhere; every search is metered,
# scoped and revocable at the gateway; zero new upstream secrets in sops.
#
# Transport chain (ONE gate, every device):
#   omp mcp.json (type:http) --funnel /install/mcp--> bootstrap-installers
#   proxies.mcp: nginx exact location, X-Mcp-Token header ACL (rendered include +
#   tmpfiles deny-stub + reload-on-rotate, the mint-gate machinery) --> loopback
#   daemon :PORTS.mcpPerplexity --> (searxng) SearXNG :PORTS.searx?format=json
#                               --> (sonar)   gateway /v1/chat/completions (sonar-pro).
#   The daemon never leaves loopback, so no service-graph edge and no Suricata
#   SG-DRIFT entry are needed (same reasoning as the installer-mint daemon).
#
# Token delivery, measured-first (2026-11-15, capture-server + the omp schema):
# omp sends mcp.json `headers` values VERBATIM - no ${VAR} expansion - so the MCP
# token must appear literally wherever mcp.json is written:
#   * installed boxes: the bootstrap installer bakes it (render envsubst of
#     $MCP_PERPLEXITY_TOKEN - same channel as the scripts' keys) into
#     ~/.omp/agent/mcp.json (0600, merged).
#   * nix hosts: it MUST NOT go through /etc/omp/mcp-managed.json (a world-readable
#     Nix-store path, attic-cached) - instead the client injector unit below writes
#     it root-side from the sops mount into each user's ~/.omp/agent/mcp.json, the
#     same out-of-store doctrine as the harness key files.
# The token gates ONLY this search server (not the gateway, not the installers);
# rotation = sops set + switch on hp and each client host.
{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.MODULES.services.mcpPerplexity;

  # The funnel URL of the shared gate: on the gateway host straight from its own
  # traefik; on a client host derived through the flake configs (the amp.nix
  # cross-host doctrine) unless set by hand.
  publicGateUrl =
    if config.MODULES.services.omniroute.enable or false
    then config.MODULES.networking.traefik.funnel.urlOf "/install/mcp"
    else
      builtins.head (
        map (
          hc: hc.config.MODULES.networking.traefik.funnel.urlOf "/install/mcp"
        ) (
          builtins.attrValues (
            lib.filterAttrs (
              _: hc: (hc.config.MODULES.services.mcpPerplexity.enable or false) && (hc.config.MODULES.networking.traefik.funnel.enable or false)
            )
            nixosConfigurations
          )
        )
      );

  py = pkgs.writeText "mcp-perplexity.py" ''
    # mcp-perplexity: streamable-HTTP MCP server (web_search / web_fetch) whose LLM
    # upstream is OmniRoute's sonar route (modules/services/mcp-perplexity.nix).
    # Auth: X-Mcp-Token header (the nginx gate denies first; this is the belt).
    # The FastMCP+uvicorn+pure-ASGI-middleware shape was validated against
    # python3Packages.mcp 1.26.0 on 2026-11-15 (401 gate + init/tools/call round trip).
    import html as htmllib
    import ipaddress
    import json
    import os
    import re
    import socket
    import sys
    import urllib.error
    import urllib.parse
    import urllib.request

    import uvicorn
    from mcp.server.fastmcp import FastMCP

    UPSTREAM = os.environ["PPLX_UPSTREAM"].rstrip("/")       # gateway /v1 base
    UPSTREAM_KEY_FILE = os.environ["PPLX_UPSTREAM_KEY_FILE"]  # path holding the sk- key
    UPSTREAM_MODEL = os.environ.get("PPLX_MODEL", "openrouter/perplexity/sonar-pro")
    TOKEN_FILE = os.environ["PPLX_TOKEN_FILE"]
    PORT = int(os.environ.get("PPLX_PORT", "8150"))
    MAX_TOKENS = int(os.environ.get("PPLX_MAX_TOKENS", "1600"))
    # "searxng" (free: SearXNG web results, optionally synthesised on a free gateway
    # route) or "sonar" (the old paid OpenRouter perplexity/* path, kept as the
    # fallback). SearXNG is the default because OpenRouter's per-model billing for
    # sonar-pro ran dry twice on 2026-11-15 and the owner asked for a no-cost search.
    BACKEND = os.environ.get("PPLX_BACKEND", "searxng")
    SEARX_URL = os.environ.get("PPLX_SEARX_URL", "http://127.0.0.1:8081/search")
    SEARX_CATEGORIES = os.environ.get("PPLX_SEARX_CATEGORIES", "general")
    SEARX_USER_AGENT = "Mozilla/5.0 (compatible; mcp-perplexity/1.0)"
    # Empty (default) = return ranked snippets and let the calling agent's own LLM
    # read them (zero extra inference cost). A model name = the daemon synthesises a
    # grounded answer first; point it at a FREE route (futurelab/*), never a paid one.
    ANSWER_MODEL = os.environ.get("PPLX_ANSWER_MODEL", "").strip()

    with open(TOKEN_FILE) as f:
        MCP_TOKEN_BYTES = f.read().strip().encode()

    SEARCH_INSTRUCTIONS = (
        "The `perplexity` MCP server gives you LIVE web data:\\n"
        "- web_search(query, max_results=5): recent events, prices, versions, docs -"
        " anything past your training data. Pass FULL QUESTIONS, not keywords.\\n"
        "- web_fetch(url): read one specific page as text.\\n"
        "When a question turns on current facts, call web_search BEFORE answering,"
        " and keep source URLs in your reply."
    )

    mcp = FastMCP("perplexity", instructions=SEARCH_INSTRUCTIONS, stateless_http=True)

    SEARCH_SYSTEM = (
        "You are a web-search tool answering through Perplexity Sonar. Answer with"
        " concrete facts and inline the source URLs. End your answer with a line"
        " `SOURCES:` followed by one URL per line (most load-bearing first)."
    )

    SYNTH_SYSTEM = (
        "You are a research assistant. Answer the query using ONLY the numbered"
        " sources provided; cite them inline as [n]. If the sources do not answer"
        " it, say so plainly. Be concrete and short."
    )


    class Upstream:
        """The one HTTP speaker to the gateway; re-reads the minted key on change
        (a re-mint lands without a daemon restart)."""

        def __init__(self):
            self._key = None
            self._mtime = None

        @property
        def key(self):
            try:
                m = os.stat(UPSTREAM_KEY_FILE).st_mtime
            except OSError:
                m = None
            if m != self._mtime:
                with open(UPSTREAM_KEY_FILE) as f:
                    self._key = f.read().strip()
                self._mtime = m
            return self._key

        def chat(self, system, user, model=None, max_tokens=None):
            body = {
                "model": model or UPSTREAM_MODEL,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                "max_tokens": max_tokens or MAX_TOKENS,
                "temperature": 0.2,
                "stream": False,
            }
            req = urllib.request.Request(
                UPSTREAM + "/chat/completions",
                data=json.dumps(body).encode(),
                headers={
                    "Authorization": "Bearer " + self.key,
                    "Content-Type": "application/json",
                    "User-Agent": "mcp-perplexity/1.0",
                },
            )
            with urllib.request.urlopen(req, timeout=150) as r:
                data = json.loads(r.read().decode())
            try:
                msg = data["choices"][0]["message"]
                text = msg.get("content") or ""
            except (KeyError, IndexError, TypeError):
                raise RuntimeError("upstream shape changed: %r" % (sorted(data),))
            cites = msg.get("citations") or []
            urls = [c if isinstance(c, str) else (c.get("url") or "") for c in cites]
            return text, [u for u in urls if u]


    upstream = Upstream()

    # ---- SearXNG backend (free) -------------------------------------------------
    # The paid-Sonar path kept dying on OpenRouter's per-model billing (measured
    # twice 2026-11-15: HTTP 402 "Model perplexity/sonar-pro out of credits"), and
    # the owner asked for a search that costs nothing. SearXNG (already fleet-run,
    # PORTS.searx, format=json enabled in modules/services/searx.nix) does the
    # actual web work; the answer synthesis, when PPLX_ANSWER_MODEL names one,
    # runs on a FREE gateway route (e.g. futurelab/*, the owner's own GPUs).
    # With no answer model the caller gets the raw ranked snippets and its own LLM
    # reads them - the agent calling this MCP is an LLM already.
    def searx_search(query, max_results):
        url = SEARX_URL + "?" + urllib.parse.urlencode(
            {"q": query, "format": "json", "categories": SEARX_CATEGORIES}
        )
        req = urllib.request.Request(url, headers={"User-Agent": SEARX_USER_AGENT})
        with urllib.request.urlopen(req, timeout=25) as r:
            data = json.loads(r.read().decode())
        out = []
        for res in (data.get("results") or [])[: max(1, min(max_results, 10))]:
            out.append(
                {
                    "title": res.get("title") or "",
                    "url": res.get("url") or "",
                    "snippet": (res.get("content") or "")[:600],
                }
            )
        return out


    @mcp.tool()
    def web_search(query: str, max_results: int = 5) -> dict:
        """Search the live web. Query = a full question or keywords. Returns an
        answer plus source URLs (or ranked snippets when no answer model is set)."""
        if BACKEND == "sonar":
            text, urls = upstream.chat(
                SEARCH_SYSTEM,
                "Use at most %d sources. Query: %s" % (max_results, query),
            )
            return {"answer": text, "sources": urls}
        try:
            results = searx_search(query, max_results)
        except Exception as e:  # noqa: BLE001 - surface searxng failures as tool text
            return {"error": "searxng failed: %s" % e, "query": query}
        if not ANSWER_MODEL or not results:
            return {"query": query, "results": results}
        context = "\n\n".join(
            "[%d] %s\n%s\n%s" % (i + 1, r["title"], r["url"], r["snippet"])
            for i, r in enumerate(results)
        )
        try:
            text, _ = upstream.chat(
                SYNTH_SYSTEM,
                "Query: %s\n\nSources:\n%s" % (query, context),
                model=ANSWER_MODEL,
            )
        except Exception as e:  # noqa: BLE001 - the snippets are still worth returning
            return {"query": query, "results": results, "synthesis_error": str(e)}
        return {
            "answer": text,
            "sources": [r["url"] for r in results],
            "results": results,
        }


    URL_RE = re.compile(r"^https?://")


    def _public_host(url):
        """SSRF guard (the daemon lives on the gateway host - every loopback service
        is one fetch away for a prompt-injected agent): resolve and refuse
        loopback/private/link-local/reserved targets. DNS-rebind races are out of
        scope (the gate is fleet-token holders, not the public); this is the cheap
        and effective layer."""
        host = urllib.parse.urlparse(url).hostname or ""
        try:
            infos = socket.getaddrinfo(host, None)
        except OSError:
            raise ValueError("dns failed for %r" % host)
        for info in infos:
            ip = ipaddress.ip_address(info[4][0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
                raise ValueError("refused: %r resolves to non-public %s" % (host, ip))
        return host


    @mcp.tool()
    def web_fetch(url: str, max_chars: int = 8000) -> dict:
        """Fetch one web page and return its readable text (best-effort extraction)."""
        if not URL_RE.match(url):
            return {"error": "url must be http(s)"}
        try:
            _public_host(url)
        except ValueError as e:
            return {"error": str(e), "url": url}
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; mcp-perplexity/1.0)"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read(min(max_chars * 8, 1500000))
                ctype = r.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            return {"error": "HTTP %d" % e.code, "url": url}
        except Exception as e:  # noqa: BLE001 - the agent needs the reason, not a crash
            return {"error": str(e), "url": url}
        text = raw.decode("utf-8", "replace")
        if "html" not in ctype.lower() and "<html" not in text[:2000].lower():
            text = text[:max_chars]
        else:
            text = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", text)
            text = re.sub(r"(?s)<[^>]+>", " ", text)
            text = re.sub(r"\s+", " ", htmllib.unescape(text)).strip()[:max_chars]
        return {"url": url, "content_type": ctype, "text": text}


    class TokenGate:
        """Pure-ASGI header check in front of FastMCP's Starlette app (the pattern
        validated 2026-11-15; no framework auth to fight)."""

        def __init__(self, app):
            self.app = app

        async def __call__(self, scope, receive, send):
            if scope["type"] == "http":
                headers = dict(scope.get("headers") or [])
                if headers.get(b"x-mcp-token") != MCP_TOKEN_BYTES:
                    await send({"type": "http.response.start", "status": 401, "headers": [(b"content-length", b"0")]})
                    await send({"type": "http.response.body", "body": b""})
                    return
            await self.app(scope, receive, send)


    app = TokenGate(mcp.streamable_http_app())


    def main():
        print(
            "mcp-perplexity: loopback :%d backend=%s searx=%s answer_model=%s upstream=%s model=%s"
            % (PORT, BACKEND, SEARX_URL, ANSWER_MODEL or "-", UPSTREAM, UPSTREAM_MODEL),
            file=sys.stderr,
            flush=True,
        )
        # host/port on the RUN path only; we drive the ASGI app under uvicorn at the
        # loopback bind below.
        uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")

    if __name__ == "__main__":
        main()
  '';

  pythonEnv = pkgs.python3.withPackages (ps: [ps.mcp ps.uvicorn]);
in {
  options.MODULES.services.mcpPerplexity = {
    enable = mkEnableOption ''
      the gateway-side web-search MCP server (loopback streamable-HTTP daemon;
      default backend = this host's SearXNG, free; optional answer synthesis and
      the paid `sonar` backend both ride this host's OmniRoute; published through
      the bootstrap-installers proxies.mcp gate). Client hosts set `client.users`
      instead.
    '';

    client = {
      users = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["akos"];
        description = ''
          LOCAL omp users to connect to the fleet's MCP gate: an activation unit
          merges a perplexity server entry (URL = `client.url`, header token from
          the sops mount) into each user's ~/.omp/agent/mcp.json - root-side, the
          token never enters the Nix store (omp sends header values verbatim,
          measured 2026-11-15, so there is no env-indirection option). Empty
          (default) = pure server host. Users must exist on this host (the unit
          chowns their home files root-side like modules/services/omp.nix's merge).
        '';
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://hp.tail546fb.ts.net:8443/install/mcp";
        defaultText = lib.literalExpression "the gateway host's funnel /install/mcp (derived through nixosConfigurations)";
        description = "The MCP gate URL (client hosts; the gateway host uses its own traefik funnel).";
      };
    };

    upstreamKeyFile = mkOption {
      type = types.path;
      default = config.MODULES.services.omniroute.keys.mcpPerplexity.filePath;
      defaultText = lib.literalExpression "MODULES.services.omniroute.keys.mcpPerplexity.filePath";
      description = ''
        The minted gateway key the daemon calls sonar-pro with (omniroute's seed
        unit owns the file; root reads it into /run/mcp-perplexity in preStart -
        keysDir is 0700 root by design, so the daemon user cannot read it directly,
        and copying the value into the store is what audit #7 forbids).
      '';
    };

    backend = mkOption {
      type = types.enum ["searxng" "sonar"];
      default = "searxng";
      description = ''
        How web_search gets its web data. `searxng` (default) asks this host's
        SearXNG (modules/services/searx.nix, PORTS.searx) - free, no per-model
        billing, and it is the reason this option exists: OpenRouter's per-model
        credit for perplexity/sonar-pro ran dry twice on 2026-11-15 and every
        search 402'd. `sonar` is the original path (the gateway's paid
        perplexity/* route). With `searxng` + `answerModel = ""` nothing is
        synthesised here at all: the caller receives ranked snippets and reads
        them with its own model, so a search costs zero inference too.
      '';
    };

    searxUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString config.PORTS.searx}/search";
      defaultText = "http://127.0.0.1:PORTS.searx/search";
      description = ''
        The SearXNG search endpoint (`format=json` must be in its
        `search.formats`, which modules/services/searx.nix already sets).
      '';
    };

    answerModel = mkOption {
      type = types.str;
      default = "";
      example = "futurelab/qwen3.8-flash-next";
      description = ''
        Optional gateway model that turns the SearXNG snippets into a cited
        answer. Empty (default) = no LLM call at all; the agent gets raw ranked
        results. Name a FREE route here (the futurelab/* family runs on the
        owner's GPUs) - a paid route would reintroduce the billing failure this
        option exists to dodge.
      '';
    };

    model = mkOption {
      type = types.str;
      default = "openrouter/perplexity/sonar-pro";
      description = "The gateway model id answering web_search in the `sonar` backend (must be search-capable; this one verified live 2026-11-15).";
    };

    maxTokens = mkOption {
      type = types.ints.positive;
      default = 1600;
      description = "max_tokens per upstream search call (answers are summaries, not essays).";
    };

    tokenSecret = mkOption {
      type = types.str;
      default = "mcp/perplexity_token";
      description = "sops key holding the X-Mcp-Token value (must equal the gateway host's bootstrapInstallers.apiKeys entry for the mcp proxy's tokenVar).";
    };

    pythonEnv = mkOption {
      type = types.package;
      default = pythonEnv;
      defaultText = "python3.withPackages (mcp + uvicorn)";
      description = "The daemon's interpreter env.";
    };
  };

  config = mkMerge [
    # ---------------------------------------------------------------- server ----
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = config.MODULES.services.omniroute.enable;
          message = "MODULES.services.mcpPerplexity fronts this host's OmniRoute sonar route - enable MODULES.services.omniroute on this host.";
        }
        {
          assertion = config.MODULES.services.bootstrapInstallers.proxies ? mcp;
          message = ''
            MODULES.services.mcpPerplexity is served through the bootstrap-installers
            proxies.mcp gate (funnel /install/mcp + X-Mcp-Token ACL). Register it:
              MODULES.services.bootstrapInstallers.proxies.mcp.target =
                "http://127.0.0.1:''${toString config.PORTS.mcpPerplexity}";
            (its tokenVar assertion then enforces the secret is declared).'';
        }
        {
          assertion = cfg.backend != "searxng" || config.MODULES.services.searx.enable;
          message = ''
            MODULES.services.mcpPerplexity.backend = "searxng" needs this host's
            SearXNG: enable MODULES.services.searx (or set backend = "sonar").'';
        }
      ];

      users.users.mcp-perplexity = {
        isSystemUser = true;
        group = "mcp-perplexity";
      };
      users.groups.mcp-perplexity = {};

      sops.secrets."mcp-perplexity-token" = {
        key = cfg.tokenSecret;
        owner = "mcp-perplexity";
        group = "mcp-perplexity";
        mode = "0400";
        restartUnits = ["mcp-perplexity.service"];
      };

      systemd.services.mcp-perplexity = {
        description = "Perplexity web-search MCP server (loopback, upstream=OmniRoute)";
        wantedBy = ["multi-user.target"];
        after = ["network.target" "omniroute.service" "omniroute-seed-providers.service"];
        serviceConfig = {
          ExecStart = "${cfg.pythonEnv}/bin/python3 ${py}";
          User = "mcp-perplexity";
          Group = "mcp-perplexity";
          DynamicUser = lib.mkForce false;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          # The minted gateway key is copied here root-side (below): keysDir is 0700
          # root by the audit #7 invariant, so the daemon cannot read it directly, and
          # ProtectSystem=strict makes even /run read-only (measured on hp 2026-11-15 -
          # a preStart mkdir /run/... failed). StateDirectory is the one path systemd
          # keeps writable under strict, and it is created before ExecStartPre.
          StateDirectory = "mcp-perplexity";
          # `+` = run this ONE pre-start step as root (the copy source is root-only);
          # it retries for the seed unit to mint first (the bootstrap-installers-render
          # doctrine - a first switch beats the key otherwise, measured 2026-11-14).
          ExecStartPre = "+${pkgs.writeShellScript "mcp-perplexity-key" ''
            set -eu
            for _ in $(seq 1 30); do
              [ -s ${cfg.upstreamKeyFile} ] && break
              sleep 2
            done
            install -m 0600 -o mcp-perplexity -g mcp-perplexity \
              ${cfg.upstreamKeyFile} /var/lib/mcp-perplexity/upstream.key
          ''}";
          Restart = "on-failure";
          RestartSec = "2s";
        };
        environment = {
          PPLX_UPSTREAM = "http://127.0.0.1:${toString config.PORTS.omniroute}/v1";
          PPLX_UPSTREAM_KEY_FILE = "/var/lib/mcp-perplexity/upstream.key";
          PPLX_MODEL = cfg.model;
          PPLX_BACKEND = cfg.backend;
          PPLX_SEARX_URL = cfg.searxUrl;
          PPLX_ANSWER_MODEL = cfg.answerModel;
          PPLX_MAX_TOKENS = toString cfg.maxTokens;
          PPLX_TOKEN_FILE = "/run/secrets/mcp-perplexity-token";
          PPLX_PORT = toString config.PORTS.mcpPerplexity;
        };
      };

      # The gate's upstream path: FastMCP serves the streamable endpoint at /mcp;
      # the proxy rewrites /install/mcp -> /mcp.
      MODULES.services.bootstrapInstallers.proxies.mcp = {
        target = "http://127.0.0.1:${toString config.PORTS.mcpPerplexity}";
        tokenVar = "MCP_PERPLEXITY_TOKEN";
        header = "x-mcp-token";
        upstreamPath = "/mcp";
        # The MCP SDK's streamable-HTTP server rejects foreign Host headers (421
        # DNS-rebinding guard, measured live 2026-11-15 through this very gate); its
        # default allow-list is "127.0.0.1:*"/"localhost:*" - the PORT is required
        # (bare "localhost" also 421s, measured locally the same day).
        hostHeader = "localhost:${toString config.PORTS.mcpPerplexity}";
        # Long upstream lives: a search is an upstream LLM call (the daemon's own
        # budget is 150s); buffering off keeps streamable-HTTP responses flowing.
        # The read timeout goes through the OPTION - the template's own
        # proxy_read_timeout + one here = nginx duplicate-directive = failed switch
        # (measured on hp 2026-11-15).
        readTimeout = "180s";
        extraConfig = ''
          proxy_send_timeout 30s;
          proxy_buffering off;
        '';
      };
      # The render bakes the token into the served installer script and writes the
      # ACL from the SAME value - one sops secret, both faces.
      MODULES.services.bootstrapInstallers.apiKeys.MCP_PERPLEXITY_TOKEN = cfg.tokenSecret;

      # The installer's mcp.json step (installed boxes; the nix-host half is the
      # client injector below, shared entry shape).
      MODULES.services.omp.bootstrap.mcpUrl = publicGateUrl;
    })

    # ---------------------------------------------------------------- client ----
    (mkIf (cfg.client.users != []) {
      sops.secrets."mcp-perplexity-token" = {
        key = cfg.tokenSecret;
        mode = "0400";
        restartUnits = ["mcp-perplexity-client-merge.service"];
      };

      # Root-side merge of the perplexity entry into each omp user's mcp.json,
      # token read from the sops mount (NEVER the store - /etc/omp/mcp-managed.json
      # is world-readable + attic-cached). Idempotent (jq re-asserts the named
      # server; user servers survive, the omp-mcp-merge doctrine).
      systemd.services."mcp-perplexity-client-merge" = {
        description = "Merge the fleet Perplexity MCP server into omp users' mcp.json";
        wantedBy = ["multi-user.target"];
        # After omp-mcp-merge on purpose: both units install into the SAME
        # ~/.omp/agent/mcp.json, and systemd's `install` is unlink+create - run in
        # parallel they raced and one died with "cannot change ownership ... No
        # such file or directory" (measured on legion5 2026-11-15, activation
        # rollback). Each merge preserves the other's servers (both deep-merge
        # into the existing file), so serial order fixes content determinism too.
        # Ordering after a unit that does not exist (gateway-less client) is a
        # systemd no-op.
        after = [
          "local-fs.target"
          "systemd-tmpfiles-setup.service"
          "omp-mcp-merge.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          tok="$(cat /run/secrets/mcp-perplexity-token)"
          # NOT (cfg.client.url or publicGateUrl): `or` only guards a MISSING
          # attribute, and client.url EXISTS with default null - escapeShellArg
          # stringifies null to the empty string silently (measured on legion5
          # 2026-11-15: the merge wrote an entry with an empty url). Explicit
          # null check; the publicGateUrl derivation stays lazy (only forced
          # when unset here).
          entry=$(jq -nc --arg url ${
            lib.escapeShellArg (
              if cfg.client.url != null
              then cfg.client.url
              else publicGateUrl
            )
          } --arg tok "$tok" \
            '{perplexity:{type:"http",url:$url,headers:{"X-Mcp-Token":$tok}}}')
          ${lib.concatMapStringsSep "\n" (
              u: let
                home = config.users.users.${u}.home;
                group = config.users.users.${u}.group;
                target = "${home}/.omp/agent/mcp.json";
              in ''
                # ${u}
                mkdir -p "${home}/.omp/agent"
                chown ${u}:${group} "${home}/.omp" "${home}/.omp/agent"
                chmod 0700 "${home}/.omp" "${home}/.omp/agent"
                tmp="$(mktemp)"
                if [ -s "${target}" ] && jq -e . "${target}" >/dev/null 2>&1; then
                  # Deep-merge ONLY mcpServers.perplexity; user servers and the rest
                  # of the file survive untouched (the omp-mcp-merge doctrine).
                  jq -s '.[0] * {mcpServers: (((.[0].mcpServers // {}) * .[1]))}' \
                    "${target}" <(printf '%s' "$entry") >"$tmp"
                else
                  printf '%s' "$entry" | jq '{mcpServers: .}' >"$tmp"
                fi
                if cmp -s "$tmp" "${target}" 2>/dev/null; then
                  rm -f "$tmp"
                else
                  install -m 0600 -o ${u} -g ${group} "$tmp" "${target}"
                fi
                rm -f "$tmp"
              ''
            )
            cfg.client.users}
        '';
        path = [pkgs.jq];
      };
    })
  ];
}
