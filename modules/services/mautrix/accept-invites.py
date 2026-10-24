"""Join every room the admin was invited to by a bridge (bot or ghost), as the admin.

Logs in with the admin's password through the (compat) /login endpoint and logs out again at
the end, so no long-lived credential is ever held: under MAS the admin is not an appservice
user anymore - no appservice may act on its behalf, so every call has to carry a real access
token belonging to the admin itself.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOMESERVER = os.environ["MATRIX_HOMESERVER"].rstrip("/")
USER_ID = os.environ["MATRIX_USER_ID"]
DOMAIN = USER_ID.split(":", 1)[1]
INVITER = re.compile(os.environ["INVITER_REGEX"])
BRIDGE_BOTS = os.environ.get("BRIDGE_BOTS", "").split()
SPACE_NAME = "Bridges"
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "admin_password")) as f:
    PASSWORD = f.read().strip()

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


def request(method, path, token=None, query=None, body=None, none_on_404=False):
    url = HOMESERVER + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404 and none_on_404:
            return None
        raise


def room_path(room_id, suffix=""):
    return "/_matrix/client/v3/rooms/%s%s" % (urllib.parse.quote(room_id, safe=""), suffix)


def is_space(token, room_id):
    # GET /state/<type> answers with the event's *content* object directly, no wrapper.
    create = request("GET", room_path(room_id, "/state/m.room.create"), token, none_on_404=True)
    if not create or create.get("type") != "m.space":
        return False
    name = request("GET", room_path(room_id, "/state/m.room.name"), token, none_on_404=True)
    return (name or {}).get("name") == SPACE_NAME


def ensure_space(token):
    for room_id in request("GET", "/_matrix/client/v3/joined_rooms", token)["joined_rooms"]:
        if is_space(token, room_id):
            return room_id
    created = request("POST", "/_matrix/client/v3/createRoom", token, body={
        "name": SPACE_NAME,
        "creation_content": {"type": "m.space"},
        "preset": "private_chat",
    })
    print("created space %s (%s)" % (created["room_id"], SPACE_NAME))
    return created["room_id"]


def ensure_space_children(token, space_id):
    """File every one-on-one room shared with a bridge bot under the space."""
    me = USER_ID
    for room_id in request("GET", "/_matrix/client/v3/joined_rooms", token)["joined_rooms"]:
        if room_id == space_id:
            continue
        members = request("GET", room_path(room_id, "/members"), token,
                          query={"membership": "join"}).get("chunk", [])
        others = [ev["state_key"] for ev in members if ev["state_key"] != me]
        if len(others) != 1 or not INVITER.match(others[0]):
            continue
        child = request("GET", room_path(space_id, "/state/m.space.child/" + urllib.parse.quote(room_id, safe="")),
                        token, none_on_404=True)
        if child:
            continue
        request("PUT", room_path(space_id, "/state/m.space.child/" + urllib.parse.quote(room_id, safe="")),
                token, body={"via": [DOMAIN]})
        print("added %s to %s" % (room_id, SPACE_NAME))


def m_direct(token):
    return request("GET", "/_matrix/client/v3/user/%s/account_data/m.direct" % urllib.parse.quote(USER_ID, safe=""),
                   token, none_on_404=True) or {}


def bot_rooms(token, space_id):
    """bot id -> [(create_ts, room_id)] over every joined one-on-one room with a bridge bot."""
    out = {}
    for room_id in request("GET", "/_matrix/client/v3/joined_rooms", token)["joined_rooms"]:
        if room_id == space_id:
            continue
        members = request("GET", room_path(room_id, "/members"), token,
                          query={"membership": "join"}).get("chunk", [])
        others = [ev["state_key"] for ev in members if ev["state_key"] != USER_ID]
        if len(others) != 1 or not INVITER.match(others[0]):
            continue
        create = request("GET", room_path(room_id, "/state/m.room.create"), token, none_on_404=True) or {}
        out.setdefault(others[0], []).append((int(create.get("origin_server_ts", 0)), room_id))
    return out


def ensure_bridge_dms(token, space_id):
    """Exactly one live management DM per bridge bot - create missing ones, collapse duplicates.

    Coverage is measured by actual membership, not m.direct: createRoom(is_direct) does not
    update m.direct (client-side convention), which made the first version of this check open
    yet another DM on every timer tick (2026-10-24). m.direct is then maintained so Element
    files the kept rooms under People, and a bot whose DM list is non-empty but has no joined
    room stays that way - a DM the admin deliberately left is not resurrected. In a duplicate
    set the newest room wins (the bridges re-register their management notices into the most
    recent invite); older ones are left and removed from the space (empty m.space.child
    content = child gone per MSC1772).
    """
    rooms = bot_rooms(token, space_id)
    dm = m_direct(token)
    dm_changed = False
    for bot in BRIDGE_BOTS:
        dups = sorted(rooms.get(bot, []))
        if dups:
            for _, extra in dups[:-1]:
                request("POST", room_path(extra, "/leave"), token, body={})
                child = room_path(space_id, "/state/m.space.child/" + urllib.parse.quote(extra, safe=""))
                if request("GET", child, token, none_on_404=True):
                    request("PUT", child, token, body={})
                print("left duplicate DM %s (%s)" % (extra, bot))
            keep = dups[-1][1]
        elif dm.get(bot):
            continue
        else:
            created = request("POST", "/_matrix/client/v3/createRoom", token, body={
                "preset": "trusted_private_chat",
                "invite": [bot],
                "is_direct": True,
            })
            keep = created["room_id"]
            print("opened DM with %s (%s)" % (bot, keep))
        if bot not in dm:
            dm[bot] = [keep]
            dm_changed = True
    if dm_changed:
        request("PUT", "/_matrix/client/v3/user/%s/account_data/m.direct" % urllib.parse.quote(USER_ID, safe=""),
                token, body=dm)
        print("updated m.direct")


def inviter(invite_state):
    for ev in invite_state.get("events", []):
        if ev.get("type") == "m.room.member" and ev.get("state_key") == USER_ID:
            return ev.get("sender", "")
    return ""


def do_login():
    body = {
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": USER_ID},
        "password": PASSWORD,
        "initial_device_display_name": "mautrix-accept-invites",
    }
    # rc_login is shared with Hermes and the reader on 127.0.0.1; a burst occasionally burns
    # our bucket. The timer retries the whole run, but one short local wait covers the common
    # case without leaving a failed unit in the journal.
    for attempt in range(3):
        try:
            return request("POST", "/_matrix/client/v3/login", body=body)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 2:
                raise
            wait = int(json.loads(e.read()).get("retry_after_ms", 5000)) / 1000
            print("login rate limited, waiting %.1fs" % wait, file=sys.stderr)
            time.sleep(wait + 1)


def main():
    login = do_login()
    token = login["access_token"]
    failed = 0
    try:
        sync = request("GET", "/_matrix/client/v3/sync", token, query={"filter": FILTER, "timeout": "0"})
        for room_id, room in sync.get("rooms", {}).get("invite", {}).items():
            sender = inviter(room.get("invite_state", {}))
            if not INVITER.match(sender):
                continue
            try:
                request("POST", room_path(room_id, "/join"), token, body={})
                print("joined %s (invited by %s)" % (room_id, sender))
            except Exception as e:  # keep going; the next run retries
                failed += 1
                print("failed to join %s: %s" % (room_id, e), file=sys.stderr)
        try:
            space_id = ensure_space(token)
            ensure_bridge_dms(token, space_id)
            ensure_space_children(token, space_id)
        except Exception as e:
            failed += 1
            print("bridge/space upkeep failed: %s" % e, file=sys.stderr)
    finally:
        # Each run is a fresh device; without this the device list grows every timer tick.
        try:
            request("POST", "/_matrix/client/v3/logout", token, body={})
        except Exception as e:
            print("logout failed: %s" % e, file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
