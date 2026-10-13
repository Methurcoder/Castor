#!/usr/bin/env python3
import gc
import io
import hashlib
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load_model


DEFAULT_MODEL = os.environ.get(
    "POME_TTS_MODEL",
    "mlx-community/Irodori-TTS-600M-v3-VoiceDesign-8bit",
)
IRODORI_NUM_STEPS = int(os.environ.get("POME_IRODORI_NUM_STEPS", "6"))
loaded_model = None
loaded_model_name = None
model_lock = threading.Lock()


def model_for(name):
    global loaded_model, loaded_model_name
    with model_lock:
        if loaded_model is None or loaded_model_name != name:
            print(f"Loading neural voice model: {name}", flush=True)
            loaded_model = None
            loaded_model_name = None
            gc.collect()
            try:
                import mlx.core as mx

                mx.clear_cache()
            except Exception:
                pass
            loaded_model = load_model(name)
            loaded_model_name = name
    return loaded_model


def preload_default_model():
    try:
        model_for(DEFAULT_MODEL)
        print(f"Neural voice model is ready: {DEFAULT_MODEL}", flush=True)
    except Exception as error:
        print(f"Neural voice preload failed: {error}", flush=True)


def generate_audio(model, model_name, payload, text):
    speed = min(max(float(payload.get("speed", 1.0)), 0.7), 1.35)
    common = {
        "text": text,
        "instruct": payload.get("instruct"),
        "stream": False,
        "verbose": False,
    }

    if "irodori-tts" in model_name.lower():
        voice_id = str(payload.get("voice") or "castor")
        voice_seed = int.from_bytes(
            hashlib.sha256(voice_id.encode("utf-8")).digest()[:4],
            "big",
        )
        return model.generate(
            **common,
            duration_scale=1.0 / speed,
            num_steps=int(payload.get("num_steps", IRODORI_NUM_STEPS)),
            rng_seed=voice_seed,
            t_schedule_mode="sway",
            sway_coeff=-1.0,
        )

    return model.generate(
        **common,
        voice=payload.get("voice"),
        speed=speed,
        lang_code=payload.get("lang_code", "auto"),
        max_tokens=min(320, max(96, len(text) * 4)),
    )


class SpeechHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        self.send_json(
            200,
            {
                "status": "ready",
                "model": loaded_model_name,
                "models": [loaded_model_name] if loaded_model_name else [],
            },
        )

    def do_POST(self):
        if self.path == "/v1/audio/preload":
            self.preload_model()
            return
        if self.path != "/v1/audio/speech":
            self.send_error(404)
            return

        try:
            payload = self.read_json()
            text = str(payload.get("input", "")).strip()
            if not text:
                raise ValueError("input is required")

            model_name = payload.get("model") or DEFAULT_MODEL
            model = model_for(model_name)
            chunks = []
            sample_rate = None
            started_at = time.perf_counter()
            for result in generate_audio(model, model_name, payload, text):
                chunks.append(np.asarray(result.audio, dtype=np.float32))
                sample_rate = result.sample_rate

            if not chunks or sample_rate is None:
                raise RuntimeError("No audio was generated")

            audio = chunks[0] if len(chunks) == 1 else np.concatenate(chunks)
            output = io.BytesIO()
            audio_write(output, audio, sample_rate, format="wav")
            data = output.getvalue()
            elapsed = time.perf_counter() - started_at

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Server-Timing", f'tts;dur={elapsed * 1000:.0f}')
            self.send_header("X-Pomegranate-TTS-Model", model_name)
            self.end_headers()
            self.wfile.write(data)
            print(
                f"Generated {len(text)} chars in {elapsed:.2f}s "
                f"with {model_name}",
                flush=True,
            )
        except Exception as error:
            self.send_json(500, {"error": str(error)})

    def preload_model(self):
        try:
            payload = self.read_json()
            model_name = str(payload.get("model") or "").strip()
            if not model_name:
                raise ValueError("model is required")
            model_for(model_name)
            self.send_json(200, {"status": "ready", "model": model_name})
        except Exception as error:
            self.send_json(500, {"error": str(error)})

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length))

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
    address = ("127.0.0.1", 8000)
    print(f"Castor neural TTS listening at http://{address[0]}:{address[1]}", flush=True)
    server = HTTPServer(address, SpeechHandler)
    if os.environ.get("POME_TTS_PRELOAD", "1") != "0":
        threading.Thread(target=preload_default_model, daemon=True).start()
    server.serve_forever()
