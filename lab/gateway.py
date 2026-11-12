"""Round-robin gateway for the two Kind clusters."""

import hmac
import itertools
import json
import re
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import urlopen


BACKENDS = {"east": sys.argv[1], "west": sys.argv[2]}
TOKEN = Path("/lab/token").read_text().strip()
ENABLED = {name: True for name in BACKENDS}
DRAINED_REVISIONS = {}
COMPLETED_REVISIONS = {}
EVENTS = deque(maxlen=200)
TURN = itertools.count()
LOCK = threading.Lock()


def record_transition(region, action, revision):
    event = {
        "time": time.time(),
        "region": region,
        "action": action,
        "revision": revision,
    }
    EVENTS.append(event)
    return event


def drain_backend(region, revision):
    with LOCK:
        if COMPLETED_REVISIONS.get(region) == revision:
            return 200, {"changed": False}
        if not ENABLED[region]:
            DRAINED_REVISIONS[region] = revision
            return 200, {"changed": False}
        if sum(ENABLED.values()) == 1:
            return 503, {"error": "Cannot drain the last enabled backend"}
        ENABLED[region] = False
        DRAINED_REVISIONS[region] = revision
        return 200, record_transition(region, "drain", revision)


def enable_backend(region, revision):
    with LOCK:
        if ENABLED[region] or COMPLETED_REVISIONS.get(region) == revision:
            return 200, {"changed": False}
        if DRAINED_REVISIONS[region] != revision:
            return 409, {"error": "Backend was drained for a different revision"}
    try:
        with urlopen(BACKENDS[region] + "/", timeout=2) as response:
            response.read()
    except (URLError, TimeoutError):
        return 503, {"error": "Backend is not ready"}
    with LOCK:
        if ENABLED[region] or COMPLETED_REVISIONS.get(region) == revision:
            return 200, {"changed": False}
        if DRAINED_REVISIONS[region] != revision:
            return 409, {"error": "Backend was drained for a different revision"}
        COMPLETED_REVISIONS[region] = revision
        ENABLED[region] = True
        del DRAINED_REVISIONS[region]
        return 200, record_transition(region, "enable", revision)


class Gateway(BaseHTTPRequestHandler):
    def send_json(self, status, payload, head=False):
        body = json.dumps(payload).encode() + b"\n"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def do_GET(self):
        self.route(head=False)

    def do_HEAD(self):
        self.route(head=True)

    def route(self, head):
        url = urlsplit(self.path)
        if url.path in ("/_lab/status", "/_lab/events"):
            with LOCK:
                data = (
                    {"enabled": ENABLED.copy()}
                    if url.path.endswith("status")
                    else list(EVENTS)
                )
            return self.send_json(200, data, head)
        with LOCK:
            regions = [region for region, enabled in ENABLED.items() if enabled]
            if regions:
                start = next(TURN) % len(regions)
                regions = regions[start:] + regions[:start]
        path = url.path + ("?" + url.query if url.query else "")
        for region in regions:
            try:
                with urlopen(BACKENDS[region] + path, timeout=2) as response:
                    body = response.read()
                    content_type = response.headers.get("Content-Type", "text/plain")
                    status = response.status
            except (URLError, TimeoutError):
                continue
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Lab-Region", region)
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return
        self.send_json(503, {"error": "No healthy backend"}, head)

    def do_POST(self):
        parts = urlsplit(self.path).path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "_lab" or parts[1] not in BACKENDS:
            return self.send_json(404, {"error": "Unknown route"})
        _, region, action = parts
        if action not in ("drain", "enable"):
            return self.send_json(404, {"error": "Unknown action"})
        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth.encode(), ("Bearer " + TOKEN).encode()):
            return self.send_json(403, {"error": "Invalid token"})
        revision = self.headers.get("X-Lab-Revision", "")
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
            return self.send_json(400, {"error": "Expected a Git commit SHA"})
        if action == "drain":
            return self.send_json(*drain_backend(region, revision))
        self.send_json(*enable_backend(region, revision))


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Gateway).serve_forever()
