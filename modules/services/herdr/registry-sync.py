"""Bridge only portable hc machine records; never share the core's own state.

Each Syncthing participant owns one operation file, avoiding concurrent edits to
machines.json and Syncthing conflict copies. Tombstones propagate hc machine rm;
Lamport clocks with a node-name tie break converge even with skewed wall clocks.
The private baseline distinguishes local hc edits from our last imported view.
"""
import json
import os
from pathlib import Path
import pwd
import re
import socket
import subprocess
import sys
import tempfile

FIELDS = {"name", "target", "via", "temporary", "session", "id", "host", "version"}


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def atomic_json(path, value, uid, gid):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if path.exists() and path.read_bytes() == data:
        return
    fd, tmp = tempfile.mkstemp(prefix=".registry-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            os.fchown(stream.fileno(), uid, gid)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def machine(row):
    if not isinstance(row, dict):
        raise ValueError("hc machine record is not an object")
    if row.get("via", False) or row.get("temporary", False):
        return None  # shell commands and short-lived/provider-local targets stay local
    for field in ("name", "target", "id", "host", "version"):
        if not isinstance(row.get(field), str):
            raise ValueError(f"hc machine record lacks string {field}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,31}", row["name"]):
        raise ValueError("invalid hc machine name")
    if not re.fullmatch(r"[a-f0-9]{32}", row["id"]):
        raise ValueError("invalid remote core ID")
    target = row["target"]
    if not target or target.startswith("-") or any(c.isspace() or ord(c) < 32 for c in target):
        raise ValueError("invalid portable SSH target")
    session = row.get("session")
    if session is not None and (not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", session)):
        raise ValueError("invalid remote hc session")
    return {k: row.get(k) for k in FIELDS} | {"via": False, "temporary": False}


def portable(rows, aliases, own_id):
    result = {}
    for row in rows:
        record = machine(row)
        if record is not None and record["id"] != own_id:
            record["target"] = aliases.get(record["target"], record["target"])
            if record["id"] in result:
                raise ValueError("duplicate remote core ID in hc registry")
            result[record["id"]] = record
    return result


def restart_core(settings, ledger, ledger_path, account):
    if not ledger.get("restart"):
        return
    # core.lock contains the actual socket (including an hc config socket override).
    # Do not use `hc server status`: it may autostart a core. Never start one just
    # because the bridge ran; an inactive core reads machines.json on next use.
    lock = Path(settings["state"]) / "core.lock"
    endpoint = lock.read_text() if lock.exists() else ""
    running = False
    if endpoint:
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.connect(endpoint)
                running = True
            except (ConnectionRefusedError, FileNotFoundError):
                pass
    if running:
        env = {
            "HOME": account.pw_dir,
            "USER": account.pw_name,
            "LOGNAME": account.pw_name,
            "PATH": "/run/current-system/sw/bin",
            "XDG_STATE_HOME": str(Path(settings["state"]).parent.parent),
            "XDG_RUNTIME_DIR": f"/run/user/{account.pw_uid}",
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{account.pw_uid}/bus",
            "HC_SESSION": settings["session"],
            "HC_SOCKET": endpoint,
        }
        subprocess.run(
            [settings["runuser"], "-u", account.pw_name, "--", settings["hc"], "server", "restart"],
            env=env, check=True, timeout=45,
        )
    ledger["restart"] = False
    atomic_json(ledger_path, ledger, 0, 0)


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    node = settings["node"]
    account = pwd.getpwnam(settings["user"])
    syncthing = pwd.getpwnam(settings["syncthingUser"])
    share = Path(settings["share"])
    state = Path(settings["state"])
    live = state / "machines.json"
    ledger_path = Path(settings["ledger"]) / "baseline.json"
    ledger = read_json(ledger_path, {"baseline": {}, "clock": 0, "restart": False})
    # Complete an interrupted import before comparing hc's live file with baseline.
    restart_core(settings, ledger, ledger_path, account)
    identity = read_json(state / "core.json", {})
    own_id = identity.get("id")
    original = read_json(live, [])
    if not isinstance(original, list):
        raise ValueError("hc machines.json must be an array; refusing to replace it")
    current = portable(original, settings["aliases"], own_id)
    all_ops = {}
    own = {"version": 1, "records": {}}
    for peer in settings["participants"]:
        document = read_json(share / f"{peer}.json", {"version": 1, "records": {}})
        if document.get("version") != 1 or not isinstance(document.get("records"), dict):
            raise ValueError(f"invalid registry operation file from {peer}")
        for identity_id, op in document["records"].items():
            if not re.fullmatch(r"[a-f0-9]{32}", identity_id):
                raise ValueError("invalid operation identity")
            if type(op.get("clock")) is not int or op["clock"] < 1 or type(op.get("deleted")) is not bool:
                raise ValueError("invalid registry operation clock/tombstone")
            if not op["deleted"]:
                record = machine(op.get("machine"))
                if record is None or record["id"] != identity_id:
                    raise ValueError("non-portable or mismatched registry operation")
                op = dict(op, machine=record)
            ledger["clock"] = max(ledger["clock"], op["clock"])
            previous = all_ops.get(identity_id)
            if previous is None or (op["clock"], peer) > previous[0]:
                all_ops[identity_id] = ((op["clock"], peer), op)
        if peer == node:
            own = document
    # Importing never republishes the imported view. Only local changes against
    # the private baseline become new operations in this node's own file.
    baseline = ledger["baseline"]
    for identity_id in sorted(set(current) | set(baseline)):
        if identity_id == own_id or current.get(identity_id) == baseline.get(identity_id):
            continue
        ledger["clock"] += 1
        op = {"clock": ledger["clock"], "deleted": identity_id not in current}
        if identity_id in current:
            op["machine"] = current[identity_id]
        own["records"][identity_id] = op
        all_ops[identity_id] = ((op["clock"], node), op)
    # Publish our PUBLIC destination descriptor, not core.json itself or its
    # machine_id. Each peer needs a first usable route to this participant;
    # this node still excludes its own ID from its local remote-machine list.
    if own_id is not None:
        self_record = machine({
            "name": node, "target": settings["selfTarget"], "via": False,
            "temporary": False, "session": settings["session"], "id": own_id,
            "host": identity["name"], "version": settings["version"],
        })
        previous = own["records"].get(own_id, {})
        if previous.get("deleted") is not False or previous.get("machine") != self_record:
            ledger["clock"] += 1
            previous = {"clock": ledger["clock"], "deleted": False, "machine": self_record}
            own["records"][own_id] = previous
        winner = all_ops.get(own_id)
        if winner is None or (previous["clock"], node) > winner[0]:
            all_ops[own_id] = ((previous["clock"], node), previous)
    atomic_json(share / f"{node}.json", own, syncthing.pw_uid, syncthing.pw_gid)
    wanted = {}
    for identity_id, (stamp, op) in all_ops.items():
        if not op["deleted"] and identity_id != own_id:
            record = op["machine"].copy()
            record["target"] = settings["aliases"].get(record["target"], record["target"])
            wanted[identity_id] = record
    local_only = [row for row in original if machine(row) is None]
    names = [row["name"] for row in local_only] + [row["name"] for row in wanted.values()]
    if len(names) != len(set(names)):
        raise ValueError("conflicting hc machine names; rename locally before importing")
    result = local_only + sorted(wanted.values(), key=lambda row: row["name"])
    # hc writes atomically but has no file lock. Refuse an observed concurrent
    # edit rather than overwrite it; the next timer invocation merges that edit.
    if read_json(live, []) != original:
        raise RuntimeError("hc registry changed during merge; retrying on next timer")
    changed = result != original
    if changed:
        # Save restart intent with the OLD baseline first. If interrupted before
        # the live replace, the next pass must not mistake the old live view for
        # hc deletions. After the replace, replay can only republish that view.
        ledger["restart"] = True
        atomic_json(ledger_path, ledger, 0, 0)
        atomic_json(live, result, account.pw_uid, account.pw_gid)
    ledger["baseline"] = wanted
    atomic_json(ledger_path, ledger, 0, 0)
    restart_core(settings, ledger, ledger_path, account)


if __name__ == "__main__":
    main()
