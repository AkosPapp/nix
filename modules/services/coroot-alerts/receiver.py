#!/usr/bin/env python3
"""Coroot alert webhook receiver -> Matrix.

A stdlib-only HTTP server for MODULES.services.coroot-alerts. Coroot's webhook
integration (configured by configure.py next to this file) POSTs one JSON document per
alert/incident notification here; the receiver turns it into two Matrix messages sent AS
the dedicated @coroot bot:

  1. the alert notification, posted as a message to the ADMIN (@akos) - "message me on
     matrix"; and
  2. a diagnosis request @mentioning the Hermes bot in a shared DM room, which starts a
     Hermes agent turn whose answer (a summary + diagnosis, asked to be reported to the
     admin's DM) lands next to the alert.

Rooms are created by the bot on first use (deliberately NOT encrypted: the Hermes gateway
adapter runs with MATRIX_E2EE_MODE=off and could not read encrypted rooms) and their ids
are cached under the state dir; a cached room that stops working (the bot was kicked, the
room was destroyed) is transparently recreated on the next send.

The token check is constant-time; everything else fails soft (502s Coroot logs and
retries, never a crash of the receiver).
"""

import http.server
import json
import os
import pathlib
import secrets
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid

CONFIG = {
    "host": os.environ.get("COROOT_ALERTS_LISTEN", "0.0.0.0"),
    "port": int(os.environ["COROOT_ALERTS_PORT"]),
    "homeserver": os.environ["COROOT_ALERTS_MATRIX_URL"].rstrip("/"),
    "bot": os.environ["COROOT_ALERTS_MATRIX_BOT_ID"],
    "admin": os.environ["COROOT_ALERTS_MATRIX_ADMIN_ID"],
    "hermes": os.environ.get("COROOT_ALERTS_MATRIX_AGENT_ID", ""),
    "password_file": os.environ.get("COROOT_ALERTS_PASSWORD_FILE")
    or (os.environ["CREDENTIALS_DIRECTORY"] + "/matrix_password"),
    "token_file": os.environ.get("COROOT_ALERTS_TOKEN_FILE")
    or (os.environ["CREDENTIALS_DIRECTORY"] + "/webhook_token"),
    "state_dir": pathlib.Path(os.environ.get("COROOT_ALERTS_STATE_DIR", "/var/lib/coroot-alerts")),
    "prompt": os.environ.get("COROOT_ALERTS_PROMPT", ""),
    # Comma-separated uppercased severities that wake the agent (resolved/OK alerts are
    # never diagnosed, only announced).
    "diagnose_on": {s.strip().upper() for s in os.environ.get("COROOT_ALERTS_DIAGNOSE_ON", "WARNING,CRITICAL").split(",") if s.strip()},
}

TOKEN = pathlib.Path(CONFIG["token_file"]).read_text().strip()
if not TOKEN:
    raise SystemExit("empty webhook token credential")


class MatrixError(Exception):
    def __init__(self, status, body):
        super().__init__(f"matrix HTTP {status}: {body[:300]}")
        self.status = status


class MatrixClient:
    """Minimal client-server API client: password login, DM rooms, text messages."""

    def __init__(self):
        self._token = None

    def _request(self, method, path, body=None, auth=True, retry=True):
        req = urllib.request.Request(
            CONFIG["homeserver"] + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={"Content-Type": "application/json"},
        )
        if auth and self._token:
            req.add_header("Authorization", "Bearer " + self._token)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            payload = e.read().decode(errors="replace")
            # Expired/revoked token: log in once more, then re-raise if it still fails.
            # (2026-11-14: the old retry re-issued the request with _token=None, i.e.
            # WITHOUT the Authorization header - MAS answered 401 M_MISSING_TOKEN, and a
            # MAS token lifetime (~1h) meant the first alert after every expiry burned
            # one delivery before post()'s not-CLIENT._token login recovered it.)
            if auth and retry and e.code in (401, 403) and "token" in payload.lower() and self._token:
                self._token = None
                self.login()
                return self._request(method, path, body, auth=auth, retry=False)
            raise MatrixError(e.code, payload) from None
        except OSError as e:
            raise MatrixError(0, str(e)) from None

    def login(self):
        password = pathlib.Path(CONFIG["password_file"]).read_text().strip()
        res = self._request(
            "POST",
            "/_matrix/client/v3/login",
            {
                "type": "m.login.password",
                "identifier": {"type": "m.id.user", "user": CONFIG["bot"]},
                "password": password,
                # Fixed device id: a rotating device per restart would strand the room
                # memberships' device lists; one named device reuses the same session.
                "device_id": "COROOTALERTS",
                "initial_device_display_name": "coroot-alerts receiver",
            },
            auth=False,
        )
        self._token = res["access_token"]

    def send(self, room_id, body, html, mention=None):
        content = {
            "msgtype": "m.text",
            "body": body,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }
        if mention:
            # MSC3952: the authoritative mention signal the Hermes adapter checks, on top
            # of the pill text in the body.
            content["m.mentions"] = {"user_ids": [mention]}
        txn = uuid.uuid4().hex
        room = urllib.parse.quote(room_id, safe="")
        return self._request("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}", content)

    def create_dm(self, invite, name, topic):
        # createRoom (camelCase, the spec name) NOT create_room: Synapse 1.164.2 (hp
        # switch 2026-11-13 00:44) dropped the long-deprecated snake_case alias, and the
        # receiver 404'd M_UNRECOGNIZED on every room create until this line changed
        # (incident i-h9skdlc6: every coroot webhook POST -> 502 -> coroot retried per
        # minute, which coroot counted as the receiver app's 100% error rate).
        res = self._request(
            "POST",
            "/_matrix/client/v3/createRoom",
            {
                "preset": "trusted_private_chat",
                "visibility": "private",
                # is_direct makes the Hermes adapter treat the room as a DM: invites are
                # auto-joined and the require_mention gate still applies (we mention).
                # No m.room.encryption initial_state ON PURPOSE - the agent gateway runs
                # E2EE off and could not read an encrypted room.
                "is_direct": True,
                "invite": [u for u in invite if u],
                "name": name,
                "topic": topic,
                "creation_content": {"m.federate": False},
            },
        )
        return res["room_id"]


CLIENT = MatrixClient()
# ThreadingHTTPServer serves alerts concurrently; serialize room ensure/create/recreate so
# a burst cannot race two create_room calls for one key (the loser's room would orphan).
ROOM_LOCK = threading.Lock()


def ensure_room(key, invite, name, topic):
    """Return a live room id for `key`, creating (and caching) it when absent or broken."""
    cache = CONFIG["state_dir"] / (key + ".room")
    try:
        return cache.read_text().strip()
    except OSError:
        pass
    room = CLIENT.create_dm(invite, name, topic)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(room)
    print(f"created room {key}: {room}", flush=True)
    return room


def invite(room_id, members):
    """Best-effort re-invite: heals the case where Hermes rejected (or missed) the
    original invite because the gateway's allowlist env had not been deployed yet."""
    room = urllib.parse.quote(room_id, safe="")
    for user in members:
        try:
            CLIENT._request("POST", f"/_matrix/client/v3/rooms/{room}/invite", {"user_id": user})
        except MatrixError:
            pass


def post(key, invite_list, name, topic, body, html, mention=None):
    """Send one message, recreating the room once if the cached one no longer works.

    The token is reused across posts on purpose: Synapse rate-limits login per account AND
    per source address (0.5/s - matrix.nix rc_login), and an alert storm would otherwise
    spend two fresh logins per alert on a host that already shares the 127.0.0.1 bucket
    with Hermes and the bridges. The room lifecycle (read cache / create / on-failure
    recreate) runs under ROOM_LOCK so a burst cannot race two create_room calls for one
    key and orphan a room; the actual send happens outside the lock (it's the slow part
    and is idempotent per txn id).
    """
    with ROOM_LOCK:
        if not CLIENT._token:
            CLIENT.login()
        room = ensure_room(key, invite_list, name, topic)
    if mention:
        invite(room, invite_list)
    try:
        CLIENT.send(room, body, html, mention=mention)
    except MatrixError as e:
        if e.status not in (403, 404):
            raise
        with ROOM_LOCK:
            # Re-check: another thread may already have rotated this key's room.
            cached = (CONFIG["state_dir"] / (key + ".room")).read_text().strip() if (CONFIG["state_dir"] / (key + ".room")).exists() else ""
            if cached == room or not cached:
                (CONFIG["state_dir"] / (key + ".room")).unlink(missing_ok=True)
                room = ensure_room(key, invite_list, name, topic)
            else:
                room = cached
        CLIENT.send(room, body, html, mention=mention)


def _app_of(d):
    app = d.get("application")
    if isinstance(app, dict):
        return f"{app.get('namespace','')}:{app.get('kind','')}:{app.get('name','')}"
    return str(app or "")


def _render(payload):
    """(short_text, html_body) for a coroot alert or incident notification, or None."""
    status = str(payload.get("status", "")).upper()
    url = str(payload.get("url", ""))
    app = _app_of(payload)
    esc = lambda s: (  # noqa: E731
        str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )
    link = f'<a href="{esc(url)}">{esc(url)}</a>' if url else ""
    if "rule_name" in payload:  # AlertTemplateValues
        # A resolved alert keeps its original severity; status is what says "don't diagnose".
        sev = "OK" if status == "OK" else (str(payload.get("severity", "")).upper() or status)
        icon = {"CRITICAL": "🔴", "WARNING": "🟠", "OK": "✅"}.get(sev, "ℹ️")
        head = f"{icon} {esc(status)} <b>{esc(payload.get('rule_name',''))}</b> — <code>{esc(app)}</code>"
        lines = [f"{esc(status)} {payload.get('rule_name','')} — {app}"]
        if payload.get("summary"):
            head += f"<br>{esc(payload['summary'])}"
            lines.append(str(payload["summary"]))
        for det in payload.get("details") or []:
            head += f"<br>• <b>{esc(det.get('name',''))}</b>: {esc(det.get('value',''))}"
            lines.append(f"• {det.get('name','')}: {det.get('value','')}")
        if payload.get("duration"):
            lines.append(f"active for {payload['duration']}")
        if link:
            head += f"<br>{link}"
            lines.append(url)
        return sev, "\n".join(lines), head
    if "reports" in payload:  # IncidentTemplateValues
        icon = "✅" if status == "OK" else "🔥"
        head = f"{icon} {esc(status)} incident on <code>{esc(app)}</code>"
        lines = [f"{status} incident on {app}"]
        for rep in payload.get("reports") or []:
            head += f"<br>• <b>{esc(rep.get('name',''))}</b>/{esc(rep.get('check',''))}: {esc(rep.get('message',''))}"
            lines.append(f"• {rep.get('name','')}/{rep.get('check','')}: {rep.get('message','')}")
        for rca in ("rca_summary", "rca_remediations"):
            if payload.get(rca):
                head += f"<br>{esc(payload[rca]).replace(chr(10), '<br>')}"
                lines.append(f"{rca}: {payload[rca]}")
        if link:
            head += f"<br>{link}"
            lines.append(url)
        return status, "\n".join(lines), head
    # Unknown shape: forward it verbatim rather than dropping it.
    pretty = json.dumps(payload, indent=1)
    return status, pretty, f"<pre>{esc(pretty)}</pre>"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, text=""):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self._reply(200, "ok")
        else:
            self._reply(404)

    def do_POST(self):  # noqa: N802
        if self.path not in ("/", "/hooks/coroot"):
            self._reply(404)
            return
        given = self.headers.get("x-coroot-token", "")
        if not secrets.compare_digest(given, TOKEN):
            self._reply(401, "bad token")
            return
        try:
            n = int(self.headers.get("content-length") or 0)
            payload = json.loads(self.rfile.read(n))
            assert isinstance(payload, dict)
        except Exception:
            self._reply(400, "bad payload")
            return

        try:
            sev, text, html = _render(payload)
        except Exception as e:  # never parse-crash the receiver
            self._reply(422, f"unrenderable: {e}")
            return

        # 1. The notification, straight to the admin.
        try:
            post("admin-alert", [CONFIG["admin"]], "Coroot alerts",
                 "Coroot alert notifications (from the @coroot bot).", text, html)
            notified = True
        except MatrixError as e:
            print(f"admin DM failed: {e}", flush=True)
            notified = False

        # 2. The diagnosis request, in the shared alert+agent room, only for severities
        #    listed in diagnose_on (resolved/OK alerts are announced above, not diagnosed).
        diagnosed = False
        if CONFIG["hermes"] and sev in CONFIG["diagnose_on"]:
            mention = f'<a href="https://matrix.to/#/{urllib.parse.quote(CONFIG["hermes"])}">{esc_at(CONFIG["hermes"])}</a>'
            ask = CONFIG["prompt"].replace("{alert}", text).replace("{mention}", mention)
            ask_html = CONFIG["prompt"].replace("{alert}", html).replace("{mention}", mention)
            try:
                post("agent-alert", [CONFIG["admin"], CONFIG["hermes"]], "Coroot alerts (agent)",
                     "Coroot alerts + the Hermes agent's diagnosis of them.", ask, ask_html,
                     mention=CONFIG["hermes"])
                diagnosed = True
            except MatrixError as e:
                print(f"agent DM failed: {e}", flush=True)

        if notified or diagnosed:
            self._reply(200, "ok")
        else:
            self._reply(502, "matrix delivery failed")

    def log_message(self, fmt, *args):  # journald gets our print()s; silence access logs
        pass


def esc_at(user_id):
    return user_id.lstrip("@").split(":")[0]


if __name__ == "__main__":
    print(
        f"coroot-alerts receiver on {CONFIG['host']}:{CONFIG['port']} "
        f"(bot={CONFIG['bot']} admin={CONFIG['admin']} agent={CONFIG['hermes'] or '-'} "
        f"diagnose_on={sorted(CONFIG['diagnose_on'])})",
        flush=True,
    )
    http.server.ThreadingHTTPServer((CONFIG["host"], CONFIG["port"]), Handler).serve_forever()
