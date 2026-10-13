#!/usr/bin/env python3
"""Castor pointer-target helper (Button-aware dodge, beta).

Answers one question for the sandboxed app: what control of another app
lies at a screen point, underneath the pet. A sandboxed app may not use the
macOS accessibility API on other apps, so this small local process does,
with the Accessibility permission you grant it (System Settings › Privacy &
Security › Accessibility; the first start asks).

    GET /health
    GET /target?x=<x>&y=<y>&pid=<pid>
        x, y: global screen point, top-left origin (accessibility coordinates)
        pid:  the app whose window lies under the pet at that point; the
              lookup is done inside that app, so the pet itself is skipped
    -> {"role": "AXButton", "subrole": null, "has_press": true, "enabled": true}

Only roles and flags are returned, never titles or text. Binds to
127.0.0.1 only.
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from ApplicationServices import (
    AXIsProcessTrustedWithOptions,
    AXUIElementCopyActionNames,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyElementAtPosition,
    AXUIElementCreateApplication,
    kAXTrustedCheckOptionPrompt,
)

HOST = os.environ.get("POME_POINTER_HOST", "127.0.0.1")
PORT = int(os.environ.get("POME_POINTER_PORT", "8126"))


def attribute(element, name):
    error, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if error == 0 else None


def describe(x, y, pid):
    app = AXUIElementCreateApplication(pid)
    error, element = AXUIElementCopyElementAtPosition(app, float(x), float(y), None)
    if error != 0 or element is None:
        return {"role": None, "subrole": None, "has_press": False, "enabled": None}
    error, actions = AXUIElementCopyActionNames(element, None)
    actions = list(actions or []) if error == 0 else []
    enabled = attribute(element, "AXEnabled")
    return {
        "role": attribute(element, "AXRole"),
        "subrole": attribute(element, "AXSubrole"),
        "has_press": "AXPress" in actions,
        "enabled": None if enabled is None else bool(enabled),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/health":
            trusted = AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: False})
            self.reply(200, {"status": "ready" if trusted else "needs-accessibility-permission"})
            return
        if url.path != "/target":
            self.reply(404, {"error": "not found"})
            return
        query = parse_qs(url.query)
        try:
            x, y = float(query["x"][0]), float(query["y"][0])
            pid = int(query["pid"][0])
        except (KeyError, ValueError, IndexError):
            self.reply(400, {"error": "x, y and pid are required"})
            return
        self.reply(200, describe(x, y, pid))


def main():
    if not AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True}):
        print("Grant Accessibility access to this helper's Python in System Settings, then restart it.", flush=True)
    print(f"Castor pointer-target helper at http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
