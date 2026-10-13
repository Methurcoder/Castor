#!/usr/bin/env python3
import base64
import io
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = os.environ.get("POME_LAMA_HOST", "127.0.0.1")
PORT = int(os.environ.get("POME_LAMA_PORT", "8123"))
MAX_REQUEST_BYTES = int(os.environ.get("POME_LAMA_MAX_REQUEST_BYTES", str(64 * 1024 * 1024)))

loaded_model = None
model_loading = False
model_lock = threading.Lock()


def model_status():
    if loaded_model is not None:
        return "ready"
    if model_loading:
        return "loading"
    return "idle"


def model_for_inference():
    global loaded_model, model_loading
    with model_lock:
        if loaded_model is None:
            model_loading = True
            try:
                from simple_lama_inpainting import SimpleLama

                print("Loading LaMa inpainting model", flush=True)
                loaded_model = SimpleLama()
                print("LaMa inpainting model is ready", flush=True)
            finally:
                model_loading = False
        return loaded_model


def preload_model():
    try:
        model_for_inference()
    except Exception as error:
        print(f"LaMa preload failed: {error}", flush=True)


def decode_base64_image(value, mode):
    from PIL import Image

    if not isinstance(value, str) or not value:
        raise ValueError("image and mask are required")
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as error:
        raise ValueError("invalid base64 image") from error
    with Image.open(io.BytesIO(raw)) as image:
        return image.convert(mode)


def inpaint(payload):
    from PIL import Image

    source = decode_base64_image(payload.get("image"), "RGB")
    mask = decode_base64_image(payload.get("mask"), "L")
    if source.size != mask.size:
        raise ValueError("image and mask dimensions must match")

    # LaMa expects a binary L mask where white is replaced.
    mask = mask.point(lambda value: 255 if value >= 128 else 0, mode="1").convert("L")
    model = model_for_inference()
    with model_lock:
        result = model(source, mask)
    if not isinstance(result, Image.Image):
        result = Image.fromarray(result)
    result = result.convert("RGB")
    if result.size != source.size:
        raise RuntimeError("LaMa returned an image with a different size")
    output = io.BytesIO()
    result.save(output, format="PNG", optimize=True)
    return output.getvalue()


class LaMaHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        self.send_json(200, {"status": model_status(), "model": "LaMa"})

    def do_POST(self):
        if self.path == "/v1/preload":
            try:
                model_for_inference()
                self.send_json(200, {"status": "ready", "model": "LaMa"})
            except Exception as error:
                self.send_json(500, {"error": str(error)})
            return
        if self.path != "/v1/inpaint":
            self.send_error(404)
            return

        try:
            payload = self.read_json()
            started_at = time.perf_counter()
            data = inpaint(payload)
            elapsed = time.perf_counter() - started_at
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Server-Timing", f"lama;dur={elapsed * 1000:.0f}")
            self.end_headers()
            self.wfile.write(data)
            print(f"Completed LaMa inpainting in {elapsed:.2f}s", flush=True)
        except ValueError as error:
            self.send_json(400, {"error": str(error)})
        except Exception as error:
            self.send_json(500, {"error": str(error)})

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("invalid Content-Length") from error
        if length <= 0:
            raise ValueError("request body is required")
        if length > MAX_REQUEST_BYTES:
            raise ValueError("request body is too large")
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError as error:
            raise ValueError("invalid JSON") from error

    def send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}", flush=True)


if __name__ == "__main__":
    if HOST not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("POME_LAMA_HOST must be a loopback address")
    address = (HOST, PORT)
    print(f"Castor LaMa listening at http://{address[0]}:{address[1]}", flush=True)
    server = ThreadingHTTPServer(address, LaMaHandler)
    if os.environ.get("POME_LAMA_PRELOAD", "1") != "0":
        threading.Thread(target=preload_model, daemon=True).start()
    server.serve_forever()
