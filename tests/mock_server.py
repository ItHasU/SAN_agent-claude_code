#!/usr/bin/env python3
"""Mock minimal du serveur SAN (API agent, spec §10.1). Stdlib uniquement.

Usage : mock_server.py --log FICHIER.jsonl --port-file FICHIER [--token T]
Chaque requête est enregistrée (une ligne JSON) : method, path, query, headers, body.

"""
import argparse, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

NUDGE_TYPES = ("start", "notification", "question", "done", "error")

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

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
        if self.headers.get("Authorization") != "Bearer " + self.server.token:
            return self._send(401, b'{"error":"unauthorized"}')
        p = u.path
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
