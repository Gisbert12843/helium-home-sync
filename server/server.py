#!/usr/bin/env python3
import hmac
import json
import math
import os
import re
import sqlite3
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

VERSION = "1.0.0"
# Bump only for wire format changes that older clients can't handle (see PROTOCOL.md).
PROTOCOL_VERSION = 1
HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("DB_PATH", os.path.join(HERE, "data", "helium-home-sync.db"))
ADMIN_DEVICE = "server-admin"
MAX_BODY = 5 * 1024 * 1024
MAX_CHANGES = 500
DEFAULT_LIMIT = 1000
MAX_LIMIT = 5000

with open(os.path.join(HERE, "schema.sql")) as f:
    SCHEMA = f.read()

URL_KEY_RE = re.compile(r"^[0-9a-f]{16,128}$")
CHANGE_TYPES = ("visit", "delete", "purge", "rejoin")


class ValidationError(ValueError):
    pass


def _str(c, field, max_len, required=True):
    v = c.get(field)
    if v is None and not required:
        return None
    if not isinstance(v, str) or not v or len(v) > max_len:
        raise ValidationError(f"{field} must be a non-empty string of at most {max_len} chars")
    return v


def _time(c, field):
    v = c.get(field)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0:
        raise ValidationError(f"{field} must be a positive number (ms since epoch)")
    return float(v)


def validate_change(c):
    if not isinstance(c, dict):
        raise ValidationError("change must be an object")
    ctype = c.get("type")
    cid = _str(c, "id", 256)
    device_id = _str(c, "deviceId", 128)
    if "deviceName" in c and not isinstance(c["deviceName"], str):
        raise ValidationError("deviceName must be a string")
    target = None
    if ctype == "visit":
        url = _str(c, "url", 8192)
        if not url.startswith(("http://", "https://")):
            raise ValidationError("url must be http(s)")
        url_key = _str(c, "urlKey", 128)
        if not isinstance(c.get("title", ""), str):
            raise ValidationError("title must be a string")
        ts = _time(c, "visitTime")
    elif ctype == "delete":
        url = c.get("url")
        url_key = c.get("urlKey")
        if (url is None) != (url_key is None):
            raise ValidationError("url and urlKey must both be set or both be null")
        if url is not None:
            _str(c, "url", 8192)
            _str(c, "urlKey", 128)
        ts = _time(c, "deletedAt")
    elif ctype == "purge":
        target = _str(c, "targetDeviceId", 128)
        url_key = None
        ts = _time(c, "before")
    elif ctype == "rejoin":
        url_key = None
        ts = _time(c, "at")
    else:
        raise ValidationError(f"type must be one of {', '.join(CHANGE_TYPES)}")
    if url_key is not None and not URL_KEY_RE.match(url_key):
        raise ValidationError("urlKey must be lowercase hex")
    return ctype, cid, device_id, url_key, ts, target


class Store:
    def __init__(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.conn.executescript(SCHEMA)
        self.conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('server_id', ?)", (uuid.uuid4().hex,))
        self.server_id = self.conn.execute("SELECT value FROM meta WHERE key = 'server_id'").fetchone()[0]
        self.lock = threading.Lock()

    def _purged(self, device_id, ts):
        return self.conn.execute(
            "SELECT 1 FROM changes WHERE type='purge' AND target_device = ? AND ts >= ? LIMIT 1", (device_id, ts)
        ).fetchone() is not None

    def _dead_on_arrival(self, device_id, url_key, ts):
        checks = (
            ("SELECT 1 FROM changes WHERE type='delete' AND url_key IS NULL AND ts >= ? LIMIT 1", (ts,)),
            ("SELECT 1 FROM changes WHERE type='delete' AND url_key = ? AND ts >= ? LIMIT 1", (url_key, ts)),
        )
        return any(self.conn.execute(q, args).fetchone() for q, args in checks) or self._purged(device_id, ts)

    def insert(self, changes):
        rows = [(validate_change(c), c) for c in changes]
        rows.sort(key=lambda r: r[0][0] != "rejoin")
        now = int(time.time() * 1000)
        accepted = 0
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                for (ctype, cid, device_id, url_key, ts, target), c in rows:
                    if self.conn.execute("SELECT 1 FROM changes WHERE id = ?", (cid,)).fetchone():
                        continue
                    if ctype == "visit" and self._dead_on_arrival(device_id, url_key, ts):
                        continue
                    if ctype == "rejoin":
                        lifted = self.conn.execute(
                            "UPDATE changes SET target_device = NULL WHERE type='purge' AND target_device = ?", (device_id,))
                        if not lifted.rowcount:
                            continue
                    self.conn.execute(
                        "INSERT INTO changes (id, type, device_id, url_key, ts, payload, received_at, target_device)"
                        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (cid, ctype, device_id, url_key, ts, json.dumps(c, separators=(",", ":")), now, target),
                    )
                    accepted += 1
                    if ctype == "delete" and url_key is None:
                        self.conn.execute("DELETE FROM changes WHERE type='visit' AND ts <= ?", (ts,))
                    elif ctype == "delete":
                        self.conn.execute("DELETE FROM changes WHERE type='visit' AND url_key = ? AND ts <= ?", (url_key, ts))
                    elif ctype == "purge":
                        self.conn.execute("DELETE FROM changes WHERE type='visit' AND device_id = ? AND ts <= ?", (target, ts))
                        self.conn.execute(
                            "UPDATE changes SET device_id = ? WHERE device_id = ? AND type != 'visit' AND ts <= ?",
                            (ADMIN_DEVICE, target, ts))
                self.conn.execute("COMMIT")
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
            last_seq = self._last_seq()
        return accepted, last_seq

    def _last_seq(self):
        row = self.conn.execute("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").fetchone()
        return row[0] if row else 0

    def fetch(self, since, limit):
        with self.lock:
            rows = self.conn.execute(
                "SELECT seq, device_id, payload FROM changes WHERE seq > ? ORDER BY seq LIMIT ?",
                (since, limit + 1),
            ).fetchall()
            last_seq = self._last_seq()
        has_more = len(rows) > limit
        rows = rows[:limit]
        changes = [{"seq": s, "deviceId": d, "payload": json.loads(p)} for s, d, p in rows]
        cursor = rows[-1][0] if rows else since
        return {"changes": changes, "cursor": cursor, "hasMore": has_more, "lastSeq": last_seq, "serverId": self.server_id}

    def stats(self):
        with self.lock:
            counts = dict(self.conn.execute("SELECT type, COUNT(*) FROM changes GROUP BY type").fetchall())
            devices = self.conn.execute(
                "SELECT COUNT(DISTINCT device_id) FROM changes WHERE type = 'visit'").fetchone()[0]
            last_seq = self._last_seq()
        return {
            "visits": counts.get("visit", 0),
            "deletes": counts.get("delete", 0),
            "purges": counts.get("purge", 0),
            "devices": devices,
            "lastSeq": last_seq,
            "serverId": self.server_id,
        }

    def devices(self):
        with self.lock:
            rows = self.conn.execute("""
                SELECT device_id,
                       SUM(type = 'visit'), SUM(type = 'delete'),
                       MIN(CASE WHEN type = 'visit' THEN ts END), MAX(CASE WHEN type = 'visit' THEN ts END),
                       MAX(received_at),
                       (SELECT json_extract(payload, '$.deviceName') FROM changes c2
                         WHERE c2.device_id = c.device_id ORDER BY seq DESC LIMIT 1)
                  FROM changes c
                 WHERE device_id != ?
                 GROUP BY device_id
                 ORDER BY MAX(received_at) DESC""", (ADMIN_DEVICE,)).fetchall()
        keys = ("id", "visits", "deletes", "firstVisit", "lastVisit", "lastUpload", "name")
        return [dict(zip(keys, r)) for r in rows]

    def purge_device(self, device_id, before=None):
        before = before or time.time() * 1000
        with self.lock:
            n = self.conn.execute(
                "SELECT COUNT(*) FROM changes WHERE type='visit' AND device_id = ? AND ts <= ?", (device_id, before)
            ).fetchone()[0]
            already = self._purged(device_id, before)
        if n or not already:
            self.insert([{"type": "purge", "id": f"{ADMIN_DEVICE}:purge:{uuid.uuid4().hex}", "deviceId": ADMIN_DEVICE,
                          "deviceName": "Server admin", "targetDeviceId": device_id, "before": before}])
        return n

    def prune(self, cutoff, dry_run=False):
        verb = "SELECT COUNT(*)" if dry_run else "DELETE"
        with self.lock:
            cur = self.conn.execute(f"{verb} FROM changes WHERE type='visit' AND ts < ?", (cutoff,))
            return cur.fetchone()[0] if dry_run else cur.rowcount

    def backup(self, path):
        with self.lock:
            dst = sqlite3.connect(path)
            try:
                self.conn.backup(dst)
            finally:
                dst.close()

    def vacuum(self):
        with self.lock:
            self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self.conn.execute("VACUUM")

    def integrity(self):
        with self.lock:
            return self.conn.execute("PRAGMA integrity_check").fetchone()[0]


def make_handler(store, token, quiet=False):
    token_bytes = token.encode()

    class Handler(BaseHTTPRequestHandler):
        server_version = f"HeliumHomeSync/{VERSION}"

        def log_message(self, fmt, *args):
            if not quiet:
                sys.stderr.write(f"{self.log_date_time_string()} {self.address_string()} {fmt % args}\n")

        def _send(self, status, body=None):
            data = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Max-Age", "86400")
            self.send_header("Access-Control-Expose-Headers", "X-Sync-Protocol")
            self.send_header("X-Sync-Protocol", str(PROTOCOL_VERSION))
            self.send_header("Cache-Control", "no-store")
            if body is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True

        def _error(self, status, message):
            self._send(status, {"error": message})

        def _authorized(self):
            header = self.headers.get("Authorization", "")
            given = header[7:].encode() if header.startswith("Bearer ") else b""
            if hmac.compare_digest(given, token_bytes):
                return True
            self._error(401, "invalid or missing token")
            return False

        def do_OPTIONS(self):
            self._send(204)

        def do_GET(self):
            parts = urlsplit(self.path)
            if parts.path == "/api/health":
                return self._send(200, {"ok": True, "version": VERSION, "protocol": PROTOCOL_VERSION})
            if parts.path == "/api/changes":
                if not self._authorized():
                    return
                qs = parse_qs(parts.query)
                try:
                    since = int(qs.get("since", ["0"])[0])
                    limit = int(qs.get("limit", [str(DEFAULT_LIMIT)])[0])
                except ValueError:
                    return self._error(400, "since and limit must be integers")
                if since < 0 or limit < 1:
                    return self._error(400, "since must be >= 0 and limit >= 1")
                return self._send(200, store.fetch(since, min(limit, MAX_LIMIT)))
            if parts.path == "/api/stats":
                if not self._authorized():
                    return
                return self._send(200, store.stats())
            self._error(404, "not found")

        def do_POST(self):
            if urlsplit(self.path).path != "/api/changes":
                return self._error(404, "not found")
            if not self._authorized():
                return
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._error(411, "Content-Length required")
            if length > MAX_BODY:
                self.close_connection = True
                if length <= 8 * MAX_BODY:
                    while length > 0:
                        length -= len(self.rfile.read(min(length, 65536)) or b"x" * length)
                return self._error(413, f"body larger than {MAX_BODY} bytes")
            try:
                body = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeDecodeError):
                return self._error(400, "body must be JSON")
            changes = body.get("changes") if isinstance(body, dict) else None
            if not isinstance(changes, list):
                return self._error(400, "body must be {changes: [...]}")
            if len(changes) > MAX_CHANGES:
                return self._error(400, f"at most {MAX_CHANGES} changes per request")
            try:
                accepted, last_seq = store.insert(changes)
            except ValidationError as e:
                return self._error(400, str(e))
            self._send(200, {"accepted": accepted, "lastSeq": last_seq})

    return Handler


def main():
    token = os.environ.get("SYNC_TOKEN", "")
    if not token:
        sys.exit("SYNC_TOKEN is not set. Generate one with: python3 -c 'import secrets; print(secrets.token_urlsafe(32))'")
    if len(token) < 16:
        print("warning: SYNC_TOKEN is shorter than 16 characters", file=sys.stderr)
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8787"))
    store = Store(DB_PATH)
    httpd = ThreadingHTTPServer((host, port), make_handler(store, token, quiet=os.environ.get("QUIET") == "1"))
    print(f"Helium Home Sync server {VERSION} on http://{host}:{port} (db: {DB_PATH})", file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
