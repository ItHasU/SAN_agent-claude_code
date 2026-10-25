#!/usr/bin/env python3
"""Mock minimal du serveur SAN (API agent, spec §10.1). Stdlib uniquement.

Usage : mock_server.py --log FICHIER.jsonl --port-file FICHIER [--token T]
Chaque requête est enregistrée (une ligne JSON) : method, path, query, headers, body.

"""
import argparse, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

NUDGE_TYPES = ("start", "notification", "question", "done", "error")

GOOD_ENR = "enr_goodtoken"
NEW_TOKEN = "agt_SECRETNEW"
PENDING_TOKEN = "agt_PENDINGTOK"

INBOX = {"events": [{"id": 812, "kind": "voice",
                     "from": {"viewer": "m5-bureau", "name": "Carte bureau"},
                     "created_at": "2026-10-23T15:04:12Z",
                     "clip": {"id": "c_TEST", "duration_ms": 4200,
                              "url": "/api/v1/agent/voice/c_TEST"}}],
         "has_more": False}


class H(BaseHTTPRequestHandler):
    server_version = "SANMock/0"

    def log_message(self, *a):
        pass

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _register(self, b):
        slug, etok = b.get("slug", ""), b.get("enrollment_token")
        if slug == "taken":
            return self._send(409, b'{"error":"slug_taken"}')
        if slug == "limited":
            return self._send(429, b'{"error":"rate_limited","retry_after_s":7}', extra={"Retry-After": "7"})
        if slug == "bad slug":
            return self._send(400, b'{"error":"invalid_slug"}')
        if etok is not None:
            if etok != GOOD_ENR:
                return self._send(401, b'{"error":"invalid_enrollment_token"}')
            return self._send(201, json.dumps({"slug": slug, "status": "active", "token": NEW_TOKEN, "group": "equipe"}).encode())
        return self._send(201, json.dumps({"slug": slug, "status": "pending", "token": PENDING_TOKEN}).encode())

    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        u = urllib.parse.urlsplit(self.path)
        rec = {"method": self.command, "path": u.path,
               "query": dict(urllib.parse.parse_qsl(u.query)),
               "headers": {k.lower(): v for k, v in self.headers.items()},
               "body_len": len(raw)}
        try:
            rec["body"] = json.loads(raw) if raw and "json" in (self.headers.get("Content-Type") or "") else None
        except ValueError:
            rec["body"] = "INVALID_JSON"
        if raw and rec["body"] is None:
            rec["body_hex"] = raw[:64].hex()
        with open(self.server.logfile, "a") as f:
            f.write(json.dumps(rec) + "\n")
        p = u.path
        if self.command == "POST" and p == "/api/v1/agent/register":
            return self._register(rec["body"] if isinstance(rec["body"], dict) else {})
        auth = self.headers.get("Authorization")
        if p == "/api/v1/agent/status" and self.command == "GET":
            if auth == "Bearer " + PENDING_TOKEN:
                return self._send(200, b'{"slug":"p","status":"pending"}')
            if auth in ("Bearer " + NEW_TOKEN, "Bearer " + self.server.token):
                return self._send(200, b'{"slug":"p","status":"active"}')
            return self._send(401, b'{"error":"unauthorized"}')
        if auth == "Bearer " + PENDING_TOKEN:
            return self._send(403, b'{"error":"agent_pending"}')
        if auth != "Bearer " + self.server.token:
            return self._send(401, b'{"error":"unauthorized"}')
        if self.command == "POST" and p == "/api/v1/agent/nudge":
            b = rec["body"] if isinstance(rec["body"], dict) else {}
            if "type" in b and b["type"] not in NUDGE_TYPES:
                return self._send(400, b'{"error":"invalid type"}')
            return self._send(200, b'{"ok":true}')
        if self.command == "POST" and p == "/api/v1/agent/state":
            return self._send(200, b'{"ok":true}')
        if self.command == "POST" and p == "/api/v1/agent/say":
            return self._send(202, b'{"clip":{"id":"c_SAY"}}')
        if self.command == "POST" and p == "/api/v1/agent/voice":
            return self._send(202, b'{"clip":{"id":"c_VOICE"}}')
        if self.command == "GET" and p == "/api/v1/agent/inbox":
            return self._send(200, json.dumps(INBOX).encode())
        if self.command == "GET" and p.startswith("/api/v1/agent/voice/"):
            return self._send(200, b"RIFFfakewavdata", "audio/wav")
        self._send(404, b'{"error":"not found"}')

    do_GET = do_POST = _handle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--token", default="agt_testtoken")
    a = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", 0), H)
    srv.logfile, srv.token = a.log, a.token
    open(a.port_file, "w").write(str(srv.server_port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
