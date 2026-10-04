"""OAuth2 token helper for himalaya against Outlook / Microsoft 365 IMAP and SMTP.

himalaya can only refresh OAuth2 tokens it keeps in a desktop keyring, which a headless
system service doesn't have. So it is pointed at this script instead (access-token.cmd), and
this script owns the refresh token: `login` runs Microsoft's device-code flow once (open a URL,
type a code - works from any browser, no redirect back to this machine needed), `access`
prints a valid access token and refreshes it first when it is about to expire.

CLIENT_ID, TENANT and TOKEN_FILE are substituted in by the Nix module.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "@clientId@"
TENANT = "@tenant@"
TOKEN_FILE = "@tokenFile@"

SCOPES = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
BASE = "https://login.microsoftonline.com/%s/oauth2/v2.0" % TENANT


def _post(endpoint, fields):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(BASE + endpoint, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return json.load(e)


def _save(tok, old=None):
    payload = {
        "access_token": tok["access_token"],
        # Microsoft may or may not rotate the refresh token on use.
        "refresh_token": tok.get("refresh_token") or (old or {}).get("refresh_token"),
        "expires_at": int(time.time()) + int(tok.get("expires_in", 3600)),
    }
    tmp = TOKEN_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f)
    os.replace(tmp, TOKEN_FILE)
    return payload


def login():
    flow = _post("/devicecode", {"client_id": CLIENT_ID, "scope": SCOPES})
    if "device_code" not in flow:
        sys.exit("device code request failed: %s" % flow.get("error_description", flow))
    print(flow["message"], flush=True)
    interval = int(flow.get("interval", 5))
    deadline = time.time() + int(flow.get("expires_in", 900))
    while time.time() < deadline:
        time.sleep(interval)
        tok = _post(
            "/token",
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": CLIENT_ID,
                "device_code": flow["device_code"],
            },
        )
        if "access_token" in tok:
            _save(tok)
            print("Logged in; token stored in %s" % TOKEN_FILE)
            return
        err = tok.get("error")
        if err == "slow_down":
            interval += 5
        elif err != "authorization_pending":
            sys.exit("login failed: %s" % tok.get("error_description", err))
    sys.exit("login timed out")


def access():
    try:
        with open(TOKEN_FILE) as f:
            cur = json.load(f)
    except FileNotFoundError:
        sys.exit("not logged in: run `outlook-oauth login` first")
    if cur["expires_at"] - 120 < time.time():
        tok = _post(
            "/token",
            {
                "grant_type": "refresh_token",
                "client_id": CLIENT_ID,
                "refresh_token": cur["refresh_token"],
                "scope": SCOPES,
            },
        )
        if "access_token" not in tok:
            sys.exit("refresh failed (run `outlook-oauth login` again): %s" % tok.get("error_description", tok))
        cur = _save(tok, cur)
    print(cur["access_token"])


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "login":
        login()
    elif cmd == "access":
        access()
    else:
        sys.exit("usage: outlook-oauth login|access")
