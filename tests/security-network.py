"""Exercise hp's generated ingress policy in disposable network namespaces.

Run as root: unshare --net python3 tests/security-network.py RULES_FILE NFT_BINARY
No production interfaces or rules are changed. The test deliberately installs an
earlier blanket ACCEPT, reproducing Tailscale's bypass of the old iptables graph.
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


if os.readlink("/proc/self/ns/net") == os.readlink("/proc/1/ns/net"):
    raise SystemExit("Refusing to run in the host network namespace; use unshare --net")

rules, nft = sys.argv[1:]
python = sys.executable
child = subprocess.Popen(["unshare", "--net", "sleep", "120"])
sockets = []
try:
    for _ in range(100):
        if os.readlink(f"/proc/{child.pid}/ns/net") != os.readlink("/proc/self/ns/net"):
            break
        time.sleep(0.01)
    else:
        raise RuntimeError("client namespace did not start")

    def client(*args, **kwargs):
        return run("nsenter", "-t", str(child.pid), "-n", *args, **kwargs)

    run("ip", "link", "set", "lo", "up")
    run("ip", "link", "add", "tailscale0", "type", "veth", "peer", "name", "client0")
    run("ip", "link", "set", "client0", "netns", str(child.pid))
    run("ip", "addr", "add", "100.92.36.52/32", "dev", "tailscale0")
    run("ip", "-6", "addr", "add", "fd7a:115c:a1e0::1/64", "dev", "tailscale0", "nodad")
    run("ip", "link", "set", "tailscale0", "up")
    run("ip", "route", "add", "100.64.0.0/10", "dev", "tailscale0")
    for address in ["100.126.232.60", "100.83.255.5", "100.100.1.200"]:
        client("ip", "addr", "add", address + "/32", "dev", "client0")
    client("ip", "-6", "addr", "add", "fd7a:115c:a1e0::2/64", "dev", "client0", "nodad")
    client("ip", "link", "set", "client0", "up")
    client("ip", "route", "add", "100.92.36.52/32", "dev", "client0")

    run(nft, "-f", "-", input="""
table inet vpn_accept {
 chain input { type filter hook input priority 0; policy accept; accept; }
}
""")
    # Loading twice verifies atomic replacement is idempotent.
    run(nft, "--check", "--file", rules)
    run(nft, "--file", rules)
    run(nft, "--file", rules)

    def listen(family, port, udp=False):
        sock = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind(("::" if family == socket.AF_INET6 else "0.0.0.0", port))
        sockets.append(sock)
        if not udp:
            sock.listen()

        def serve():
            while True:
                if udp:
                    data, addr = sock.recvfrom(64)
                    sock.sendto(data, addr)
                else:
                    conn, _ = sock.accept()
                    conn.close()

        threading.Thread(target=serve, daemon=True).start()

    for family in [socket.AF_INET, socket.AF_INET6]:
        for port in [22, 443, 3003, 8031, 8132, 11434]:
            listen(family, port)
    for port in [53, 5555]:
        listen(socket.AF_INET, port, udp=True)

    probe = """
import json, socket, sys
src, dst, port, udp = sys.argv[1:]
s = socket.socket(socket.AF_INET6 if ':' in dst else socket.AF_INET,
                  socket.SOCK_DGRAM if udp == 'yes' else socket.SOCK_STREAM)
s.settimeout(0.4)
s.bind((src, 0))
try:
    s.connect((dst, int(port)))
    if udp == 'yes':
        s.send(b'probe')
        assert s.recv(64) == b'probe'
    ok = True
except (OSError, AssertionError):
    ok = False
print(json.dumps(ok))
"""

    def check(src, port, expected, udp=False):
        dst = "fd7a:115c:a1e0::1" if ":" in src else "100.92.36.52"
        result = client(python, "-c", probe, src, dst, str(port), "yes" if udp else "no",
                        capture_output=True)
        actual = json.loads(result.stdout)
        assert actual == expected, (src, port, actual, expected)
        print(f"PASS {src} {'udp' if udp else 'tcp'}/{port}: {'allowed' if actual else 'blocked'}")

    for port in [22, 443, 11434]:
        check("100.126.232.60", port, True)
    # 2026-11-14, audit #6: loki-ingest tightened to the declared pushers - akos01
    # (fleetPushTargets -> hp) stays, a reader-only peer (legion5) is refused :8031.
    check("100.83.255.5", 8031, True)
    check("100.126.232.60", 8031, False)
    for port in [3003, 8132]:
        check("100.126.232.60", port, False)
    check("100.83.255.5", 3003, True)
    check("100.100.1.200", 22, True)
    for port in [8031, 11434]:
        check("100.100.1.200", port, False)
    check("100.126.232.60", 53, True, udp=True)
    check("100.126.232.60", 5555, False, udp=True)
    check("fd7a:115c:a1e0::2", 22, True)
    check("fd7a:115c:a1e0::2", 8132, False)
    run("ip", "link", "set", "tailscale0", "name", "wt0")
    # hp's tap set is {tailscale0, wt0} (netbird guard tap, audit 2026-11-13), so a
    # rename to wt0 does NOT escape the policy - it stays inside the same tailnet
    # chain: declared traffic (22 from the tailnet sshd edge) still flows, and the
    # newly-tightened non-pushers (legion5 -> 8031, audit #6) are STILL rejected
    # under the new name. iifname sets are evaluated per packet, so tailscale's
    # interface juggling can't reorder its way past the jump.
    check("100.126.232.60", 22, True)
    check("100.126.232.60", 8031, False)
    print("PASS: policy is name-set evaluated per packet; VPN renames/reordering cannot bypass it")
finally:
    child.terminate()
    child.wait(timeout=5)
