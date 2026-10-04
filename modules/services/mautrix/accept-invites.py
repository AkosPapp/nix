"""Join every room the admin was invited to by a bridge (bot or ghost), as the admin.

Double puppeting makes the bridges join new portal rooms as the admin themselves, but only for
rooms they create or touch after it was set up, and a missed join leaves an invite to click.
This sweeps those up. Invites from anyone else are left alone.
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request

HOMESERVER = os.environ["MATRIX_HOMESERVER"].rstrip("/")
USER_ID = os.environ["MATRIX_USER_ID"]
INVITER = re.compile(os.environ["INVITER_REGEX"])
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "as_token")) as f:
    TOKEN = f.read().strip()

# Invites only: no timeline, no state, nothing for joined rooms beyond their IDs.
FILTER = json.dumps({
    "room": {
        "timeline": {"limit": 0},
        "state": {"types": []},
        "ephemeral": {"types": []},
        "account_data": {"types": []},
    },
    "presence": {"types": []},
    "account_data": {"types": []},
})


def call(method, path, query=None):
    q = {"user_id": USER_ID}
    q.update(query or {})
    req = urllib.request.Request(
        HOMESERVER + path + "?" + urllib.parse.urlencode(q),
        data=b"{}" if method == "POST" else None,
        method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def inviter(invite_state):
    for ev in invite_state.get("events", []):
        if ev.get("type") == "m.room.member" and ev.get("state_key") == USER_ID:
            return ev.get("sender", "")
    return ""


def main():
    invites = call("GET", "/_matrix/client/v3/sync", {"filter": FILTER, "timeout": "0"}).get("rooms", {}).get("invite", {})
    failed = 0
    for room_id, room in invites.items():
        sender = inviter(room.get("invite_state", {}))
        if not INVITER.match(sender):
            continue
        try:
            call("POST", "/_matrix/client/v3/rooms/%s/join" % urllib.parse.quote(room_id, safe=""))
            print("joined %s (invited by %s)" % (room_id, sender))
        except Exception as e:  # keep going; the next run retries
            failed += 1
            print("failed to join %s: %s" % (room_id, e), file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
