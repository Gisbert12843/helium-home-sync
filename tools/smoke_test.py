#!/usr/bin/env python3
# Starts server.py on a temporary database and checks the HTTP API end to end.
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TOKEN = "smoke-test-token-0123456789"

with open(os.path.join(ROOT, "server", "server.py")) as f:
    PROTOCOL = re.search(r"^PROTOCOL_VERSION = (\d+)$", f.read(), re.M).group(1)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(base, method, path, body=None, token=TOKEN):
    req = urllib.request.Request(base + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return res.status, res.headers, json.loads(res.read())
    except urllib.error.HTTPError as e:
        return e.code, e.headers, json.loads(e.read() or b"null")


def check(cond, msg):
    if not cond:
        sys.exit(f"FAIL: {msg}")
    print(f"ok    {msg}")


def run(base):
    status, headers, body = call(base, "GET", "/api/health", token=None)
    check(status == 200 and body.get("ok") is True, "health answers without a token")
    check(str(body.get("protocol")) == PROTOCOL, f"health reports protocol {PROTOCOL}")
    check(headers.get("X-Sync-Protocol") == PROTOCOL, "responses carry the X-Sync-Protocol header")

    status, headers, _ = call(base, "GET", "/api/stats", token="wrong-token")
    check(status == 401, "wrong token is rejected")
    check(headers.get("X-Sync-Protocol") == PROTOCOL, "errors carry the X-Sync-Protocol header too")

    url = "https://example.com/smoke"
    visit = {
        "type": "visit", "id": "dev-a:1:1700000000000", "deviceId": "dev-a", "deviceName": "Smoke A",
        "url": url, "urlKey": hashlib.sha256(url.encode()).hexdigest(), "title": "Smoke",
        "visitTime": 1700000000000, "transition": "link",
    }
    status, _, body = call(base, "POST", "/api/changes", {"changes": [visit]})
    check(status == 200 and body.get("accepted") == 1, "a visit is accepted")
    status, _, body = call(base, "POST", "/api/changes", {"changes": [visit]})
    check(status == 200 and body.get("accepted") == 0, "re-sending the same visit is ignored")
    status, _, body = call(base, "POST", "/api/changes", {"changes": [{**visit, "id": "x", "url": "ftp://x"}]})
    check(status == 400, "an invalid change is rejected")

    status, _, body = call(base, "GET", "/api/changes?since=0")
    payloads = [c["payload"] for c in body.get("changes", [])]
    check(status == 200 and any(p.get("id") == visit["id"] for p in payloads), "the visit can be downloaded")

    status, _, body = call(base, "GET", "/api/stats")
    check(status == 200 and body.get("visits") == 1, "stats count the visit")


def main():
    port = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        env = {**os.environ, "SYNC_TOKEN": TOKEN, "HOST": "127.0.0.1", "PORT": str(port),
               "DB_PATH": os.path.join(tmp, "smoke.db"), "QUIET": "1"}
        server = subprocess.Popen([sys.executable, os.path.join(ROOT, "server", "server.py")], env=env)
        try:
            base = f"http://127.0.0.1:{port}"
            for _ in range(50):
                try:
                    urllib.request.urlopen(base + "/api/health", timeout=1).close()
                    break
                except OSError:
                    if server.poll() is not None:
                        sys.exit("FAIL: server exited during startup")
                    time.sleep(0.1)
            else:
                sys.exit("FAIL: server did not start")
            run(base)
        finally:
            server.terminate()
            server.wait(timeout=5)
    print("all smoke tests passed")


if __name__ == "__main__":
    main()
