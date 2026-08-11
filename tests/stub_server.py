#!/usr/bin/env python3
"""HTTP stub facade for tests/run.sh.

Serves on one loopback port:
  /v1/agent/config      token auth + ETag/304 (body comes from <config_body_file>)
  /v1/agent/enroll      POST, fleet enrollment (X-Agent-Enroll-Token): mints
                        the per-server token for instance 4242
  /v1/agent/deregister  POST, token auth; appends the token to deregister.log
  /v1/ingest/job        POST, token auth; appends the body to job-reports.log
  /metadata/instance-id          "4242" — stands in for the Hetzner metadata
                                 service (CV_AGENT_METADATA_URL)
  /metadata/instance-id-foreign  "6666" — an instance outside the enroll
                                 token's project (cross-tenant test)
  /dl/<path>            static files below <downloads_root> (fake Vector
                        releases, used by the bootstrap's tarball-fallback tests)

Tokens: "good-token" and "rotated-token" authenticate (two, so the harness
can exercise in-place token rotation); "revoked-token" gets 403; anything
else 401. Enrollment tokens: "good-enroll-token" enrolls instance 4242
(→ per-server token "good-token"), gets 404 for 6666 (not in the token's
project inventory) and 400 for anything else; "revoked-enroll-token" gets
403; anything else 401.

Usage: stub_server.py <downloads_root> <config_body_file> <port_file>
The bound port is written to <port_file> once the server is listening.
"""

import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOWNLOADS_ROOT = sys.argv[1]
CONFIG_FILE = sys.argv[2]
PORT_FILE = sys.argv[3]

GOOD_TOKENS = {"good-token", "rotated-token"}
REVOKED_TOKEN = "revoked-token"
GOOD_ENROLL_TOKEN = "good-enroll-token"
REVOKED_ENROLL_TOKEN = "revoked-enroll-token"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output clean
        pass

    def _auth(self):
        token = self.headers.get("X-Agent-Token", "")
        if token == REVOKED_TOKEN:
            self.send_error(403)
            return None
        if token not in GOOD_TOKENS:
            self.send_error(401)
            return None
        return token

    def do_GET(self):
        if self.path.startswith("/dl/"):
            self._serve_download(self.path[len("/dl/"):])
        elif self.path == "/v1/agent/config":
            self._serve_config()
        elif self.path == "/metadata/instance-id":
            self._send_text(200, "4242")
        elif self.path == "/metadata/instance-id-foreign":
            self._send_text(200, "6666")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/v1/agent/enroll":
            self._serve_enroll()
        elif self.path == "/v1/ingest/job":
            if self._auth() is None:
                return
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            log = os.path.join(os.path.dirname(PORT_FILE), "job-reports.log")
            with open(log, "ab") as f:
                f.write(body + b"\n")
            payload = b'{"accepted": 1}'
            self.send_response(202)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == "/v1/agent/deregister":
            token = self._auth()
            if token is None:
                return
            log = os.path.join(os.path.dirname(PORT_FILE), "deregister.log")
            with open(log, "a") as f:
                f.write(token + "\n")
            self.send_response(204)
            self.end_headers()
        else:
            self.send_error(404)

    def _send_text(self, status, text, content_type="text/plain"):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_enroll(self):
        """Fleet enrollment (specs/12 §3): mirrors the facade's contract.

        Instance 4242 is "in the token's project inventory", 6666 exists
        on some other tenant (→ 404, never revealed further), anything
        else is a malformed claim (→ 400).
        """
        token = self.headers.get("X-Agent-Enroll-Token", "")
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if token == REVOKED_ENROLL_TOKEN:
            self._send_text(
                403, '{"error": "enrollment token revoked"}', "application/json"
            )
            return
        if token != GOOD_ENROLL_TOKEN:
            self.send_error(401)
            return
        try:
            instance_id = json.loads(body).get("instance_id", "")
        except (ValueError, AttributeError):
            instance_id = ""
        if instance_id == "4242":
            self._send_text(
                200,
                '{"token": "good-token", "server_id": 7, "resource_id": "srv_4242"}',
                "application/json",
            )
        elif instance_id == "6666":
            self.send_error(404)
        else:
            self.send_error(400)

    def _serve_download(self, rel):
        rel = os.path.normpath(rel)
        path = os.path.join(DOWNLOADS_ROOT, rel)
        if rel.startswith("..") or not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_config(self):
        if self._auth() is None:
            return
        with open(CONFIG_FILE, "rb") as f:
            body = f.read()
        etag = '"%s"' % hashlib.sha256(body).hexdigest()[:16]
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("ETag", etag)
        self.send_header("Content-Type", "application/yaml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(PORT_FILE, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
