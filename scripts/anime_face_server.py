#!/usr/bin/env python3
"""Optional localhost anime face-landmark service for Arils.

Wraps `hysts/anime-face-detector` (MIT; the vendored mmdet/mmpose parts are
Apache-2.0) behind the same shape as the other optional local helpers in this
repository: it binds 127.0.0.1 only, it is never started automatically, and
Arils falls back to its own `AnimeFaceEstimator` whenever this is not running.

It returns the detector's raw output in source-image pixels and does no
interpretation. Turning a face box and 28 landmarks into the head, eye and
mouth rectangles `PartPlan` wants is a calibration decision, so it lives in
Swift next to the numbers it was fitted from, where it can be unit tested and
re-fitted when the hand-verified set grows.

    scripts/start-anime-face.sh
    curl -s http://127.0.0.1:8131/ | python3 -m json.tool

    POST /v1/face-landmarks   {"image": "<base64 png>"}
    -> {"width": W, "height": H, "faces": [
          {"bbox": [x1, y1, x2, y2], "score": 0.99,
           "keypoints": [[x, y, score] x 28]}]}

Landmark order is the model's own: 0-4 face bottom outline, 5-7 and 8-10 the
eyebrows, 11-16 and 17-22 the eyes, 23 the nose, 24-27 the mouth outline.
"""

from __future__ import annotations

import base64
import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np

HOST = os.environ.get("ARILS_FACE_HOST", "127.0.0.1")
PORT = int(os.environ.get("ARILS_FACE_PORT", "8131"))
# faster-rcnn by default. The package also ships a yolov3 detector; it is not
# the Ultralytics AGPL lineage, but section 7.2 of the roadmap keeps YOLO out
# of this project's supply chain entirely, so the default avoids the question.
DETECTOR = os.environ.get("ARILS_FACE_DETECTOR", "faster-rcnn")
DEVICE = os.environ.get("ARILS_FACE_DEVICE", "cpu")
MAX_REQUEST_BYTES = 64 * 1024 * 1024

_detector = None
_detector_lock = threading.Lock()


def detector():
    """Loads the model on first use so start-up stays instant."""
    global _detector
    with _detector_lock:
        if _detector is None:
            from anime_face_detector import create_detector

            started = time.time()
            print(f"[face] loading {DETECTOR} on {DEVICE}", flush=True)
            _detector = create_detector(face_detector_name=DETECTOR, device=DEVICE)
            print(f"[face] ready in {time.time() - started:.1f}s", flush=True)
    return _detector


def detect(png_bytes: bytes) -> dict:
    from PIL import Image

    with Image.open(io.BytesIO(png_bytes)) as image:
        width, height = image.size
        rgb = np.asarray(image.convert("RGB"))
    bgr = np.ascontiguousarray(rgb[:, :, ::-1])

    faces = []
    for prediction in detector()(bgr):
        bbox = np.asarray(prediction["bbox"], dtype=np.float32)
        keypoints = np.asarray(prediction["keypoints"], dtype=np.float32)
        faces.append({
            "bbox": [float(v) for v in bbox[:4]],
            "score": float(bbox[4]) if bbox.shape[0] > 4 else 1.0,
            "keypoints": [[float(x), float(y), float(s)] for x, y, s in keypoints],
        })
    faces.sort(key=lambda f: f["score"], reverse=True)
    return {"width": width, "height": height, "faces": faces}


class FaceHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A002 - quieter default logging
        sys.stderr.write("[face] " + (fmt % args) + "\n")

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") not in ("", "/v1/health"):
            self._send(404, {"error": "not found"})
            return
        self._send(200, {
            "service": "arils-anime-face",
            "detector": DETECTOR,
            "device": DEVICE,
            "loaded": _detector is not None,
            "landmarks": 28,
        })

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/face-landmarks":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, {"error": "bad Content-Length"})
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self._send(413, {"error": "request too large or empty"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
            png = base64.b64decode(payload["image"])
        except Exception as error:  # noqa: BLE001
            self._send(400, {"error": f"bad request: {error}"})
            return
        try:
            self._send(200, detect(png))
        except Exception as error:  # noqa: BLE001
            self._send(500, {"error": f"detection failed: {error}"})


def main() -> int:
    if HOST not in ("127.0.0.1", "localhost", "::1"):
        print(f"[face] refusing to bind {HOST}; this service is localhost only", file=sys.stderr)
        return 2
    if os.environ.get("ARILS_FACE_PRELOAD", "0") == "1":
        # Pay the torch import and weight load now, not inside the app's first
        # face check, which waits on this with a short timeout.
        detector()
    server = HTTPServer((HOST, PORT), FaceHandler)
    print(f"[face] listening on http://{HOST}:{PORT}  detector={DETECTOR} device={DEVICE}", flush=True)
    print("[face] POST /v1/face-landmarks   GET / for health", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[face] stopping", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
