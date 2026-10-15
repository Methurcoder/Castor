#!/usr/bin/env python3
"""Local Qwen speech backend for a bundled helper, not an end-user CLI workflow.

No model loads/downloads on startup. Prepare/speech require a local app request.
Only the two official CustomVoice models are allowed; no arbitrary Python code,
model URL, microphone recording or voice-cloning input is accepted.
"""
# Divert frozen worker/resource-tracker invocations before loading the GUI/backend.
if __name__ == '__main__':
    import multiprocessing
    multiprocessing.freeze_support()

import io
import json
import math
import os
import platform
import threading
import time
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_MODEL = 'mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit'
MODELS = {
    DEFAULT_MODEL: 'Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice',
    'Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice': 'Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice',
    'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice': 'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice',
}
LANGUAGES = {'auto': 'Auto', 'ja': 'Japanese', 'en': 'English', 'zh': 'Chinese',
             'ko': 'Korean', 'de': 'German', 'fr': 'French', 'ru': 'Russian',
             'pt': 'Portuguese', 'es': 'Spanish', 'it': 'Italian'}


def validated_payload(value):
    if not isinstance(value, dict):
        raise ValueError('JSON object required')
    model = value.get('model') or DEFAULT_MODEL
    if model not in MODELS:
        raise ValueError('Unsupported official CustomVoice model')
    text = value.get('input', '')
    instruction = value.get('instruct', '')
    voice = value.get('voice', 'Ryan')
    language = value.get('lang_code', 'auto')
    speed = value.get('speed', 1.0)
    if not isinstance(text, str) or not text.strip() or len(text) > 8000:
        raise ValueError('Input must contain 1–8000 characters')
    if not isinstance(instruction, str) or len(instruction) > 4000:
        raise ValueError('Invalid voice instruction')
    if not isinstance(voice, str) or not voice or len(voice) > 256:
        raise ValueError('Invalid speaker')
    aliases = {name.lower(): code for code, name in LANGUAGES.items()}
    if isinstance(language, str): language = aliases.get(language.lower(), language.lower())
    if not isinstance(language, str) or language not in LANGUAGES:
        raise ValueError('Unsupported language code')
    if isinstance(speed, bool) or not isinstance(speed, (int, float)) or not math.isfinite(speed) or not .5 <= speed <= 2:
        raise ValueError('Speed must be 0.5–2')
    if value.get('response_format', 'wav') != 'wav' or value.get('stream', False) is not False:
        raise ValueError('Only non-streaming WAV is supported')
    return dict(model=model, input=text, instruct=instruction, voice=voice,
                lang_code=language.lower(), speed=float(speed))


class QwenBackend:
    def __init__(self):
        self.lock = threading.Lock()
        self.model = None
        self.alias = None
        self.canonical = None
        self.loading = False

    def _load(self, alias):
        if alias not in MODELS:
            raise ValueError('Unsupported official CustomVoice model')
        canonical = MODELS[alias]
        if self.model is None or canonical != self.canonical:
            os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
            import torch
            from qwen_tts import Qwen3TTSModel
            self.loading = True
            try:
                self.model = None
                self.canonical = None
                self.alias = None
                # CPU distribution works without a CUDA installation. A separately
                # approved CUDA build can use its available device.
                cuda = torch.cuda.is_available()
                self.model = Qwen3TTSModel.from_pretrained(canonical,
                    device_map='cuda:0' if cuda else 'cpu', dtype=torch.float16 if cuda else torch.float32,
                    attn_implementation='sdpa', trust_remote_code=False)
                self.canonical = canonical
            finally:
                self.loading = False
        self.alias = alias

    def preload(self, alias, cancelled):
        with self.lock:
            if cancelled.is_set():
                raise InterruptedError('Cancelled')
            self._load(alias)
            if cancelled.is_set():
                raise InterruptedError('Cancelled')

    def speech(self, payload, cancelled):
        with self.lock:
            import numpy as np
            from transformers import StoppingCriteria, StoppingCriteriaList
            if cancelled.is_set():
                raise InterruptedError('Cancelled')
            self._load(payload['model'])
            if cancelled.is_set():
                raise InterruptedError('Cancelled')

            class StopRequested(StoppingCriteria):
                def __call__(self, input_ids, scores, **kwargs):
                    return cancelled.is_set()

            instruction = payload['instruct'] if '1.7B' in self.canonical else None
            wavs, rate = self.model.generate_custom_voice(text=payload['input'], speaker=payload['voice'],
                language=LANGUAGES[payload['lang_code']], instruct=instruction, non_streaming_mode=True,
                max_new_tokens=2048, stopping_criteria=StoppingCriteriaList([StopRequested()]))
            if cancelled.is_set():
                raise InterruptedError('Cancelled')
            if len(wavs) != 1 or not 8000 <= rate <= 192000:
                raise ValueError('Invalid generated waveform')
            audio = np.asarray(wavs[0], dtype=np.float32)
            if audio.ndim != 1 or not len(audio) or len(audio) > rate * 300 or not np.isfinite(audio).all():
                raise ValueError('Invalid generated waveform')
            if payload['speed'] != 1:
                import librosa
                audio = librosa.effects.time_stretch(audio, rate=payload['speed'])
            if cancelled.is_set():
                raise InterruptedError('Cancelled')
            samples = (np.clip(audio, -1, 1) * 32767).round().astype('<i2').tobytes()
            output = io.BytesIO()
            with wave.open(output, 'wb') as writer:
                writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(rate); writer.writeframes(samples)
            result = output.getvalue()
            if len(result) > 64 * 1024 * 1024:
                raise ValueError('Generated WAV exceeds limit')
            return result


class MLXBackend(QwenBackend):
    """Apple Silicon backend; same bounded local HTTP/GUI contract as Windows."""
    def _load(self, alias):
        if alias not in (DEFAULT_MODEL, MODELS[DEFAULT_MODEL]):
            raise ValueError('This MLX helper supports Qwen 0.6B CustomVoice')
        if self.model is None:
            os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
            from mlx_audio.tts.utils import load_model
            self.loading = True
            try:
                self.model = load_model(DEFAULT_MODEL)
                self.canonical = DEFAULT_MODEL
            finally:
                self.loading = False
        self.alias = alias

    def speech(self, payload, cancelled):
        with self.lock:
            import numpy as np
            if cancelled.is_set(): raise InterruptedError('Cancelled')
            self._load(payload['model'])
            if cancelled.is_set(): raise InterruptedError('Cancelled')
            chunks = []; sample_count = 0; rate = None
            # Short streaming yields permit cancellation between generation chunks.
            # The HTTP response remains one in-memory WAV, never a stored recording.
            for result in self.model.generate(text=payload['input'], voice=payload['voice'],
                    lang_code=LANGUAGES[payload['lang_code']], instruct=None,
                    max_tokens=2048, stream=True, streaming_interval=.25, verbose=False):
                if cancelled.is_set(): raise InterruptedError('Cancelled')
                samples = np.asarray(result.audio, dtype=np.float32)
                current_rate = int(result.sample_rate)
                if samples.ndim != 1 or not np.isfinite(samples).all() or not 8000 <= current_rate <= 192000:
                    raise ValueError('Invalid generated waveform')
                if rate is not None and rate != current_rate: raise ValueError('Mixed sample rates')
                rate = current_rate; sample_count += len(samples)
                if sample_count > rate * 300: raise ValueError('Generated waveform exceeds limit')
                chunks.append(samples)
            if not chunks or not sample_count: raise ValueError('No generated waveform')
            audio = np.concatenate(chunks)
            if payload['speed'] != 1:
                from scipy.signal import resample_poly
                # A bounded playback-rate change, equivalent to the standard voice
                # rate setting. Do not claim pitch-preserving time stretching.
                audio = resample_poly(audio, 1000, round(payload['speed'] * 1000))
            if cancelled.is_set(): raise InterruptedError('Cancelled')
            output = io.BytesIO()
            with wave.open(output, 'wb') as writer:
                writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(rate)
                writer.writeframes((np.clip(audio, -1, 1) * 32767).round().astype('<i2').tobytes())
            value = output.getvalue()
            if len(value) > 64 * 1024 * 1024: raise ValueError('Generated WAV exceeds limit')
            return value


def default_backend():
    if platform.system() == 'Darwin' and platform.machine().lower() in ('arm64', 'aarch64'):
        return MLXBackend()
    return QwenBackend()


class SpeechServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address=('127.0.0.1', 8000), backend=None):
        if address[0] != '127.0.0.1':
            raise ValueError('Only IPv4 loopback binding is supported')
        super().__init__(address, SpeechHandler)
        self.backend = backend or default_backend()
        self.jobs = {}; self.jobs_lock = threading.Lock(); self.pending = {}
        self.limit = threading.BoundedSemaphore(4)

    def handle_error(self, request, client_address):
        pass  # Do not dump local traceback/paths from disconnected clients.

    def begin(self, request_id):
        with self.jobs_lock:
            if request_id in self.jobs:
                raise ValueError('Duplicate request id')
            event = threading.Event()
            now = time.monotonic()
            self.pending = {key: stamp for key, stamp in self.pending.items() if now - stamp < 30}
            if self.pending.pop(request_id, None) is not None:
                event.set()
            self.jobs[request_id] = event
            return event

    def cancel(self, request_id):
        with self.jobs_lock:
            if request_id in self.jobs:
                self.jobs[request_id].set()
            elif len(self.pending) < 128:
                self.pending[request_id] = time.monotonic()

    def finish(self, request_id):
        with self.jobs_lock:
            self.jobs.pop(request_id, None)


class SpeechHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup(); self.connection.settimeout(30)

    def json_reply(self, status, payload):
        data = json.dumps(payload).encode('utf-8')
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers()
        self.wfile.write(data)

    def allowed(self):
        # Native loopback clients send neither Origin nor browser fetch headers.
        if self.headers.get('Origin') or self.headers.get('Sec-Fetch-Site') == 'cross-site':
            self.json_reply(403, {'error': 'Native local app request required'}); return False
        return True

    def read_json(self):
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length <= 128 * 1024 or self.headers.get('Transfer-Encoding'):
            raise ValueError('Invalid request size')
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if not self.allowed(): return
        if self.path not in ('/', '/v1/audio/status'): self.send_error(404); return
        backend = self.server.backend
        self.json_reply(200, {'status': 'loading' if backend.loading else 'ready' if backend.alias else 'idle',
            'model': backend.alias, 'models': [DEFAULT_MODEL, MODELS[DEFAULT_MODEL]] if isinstance(backend, MLXBackend) else list(MODELS), 'instructionControl': bool(backend.canonical and '1.7B' in backend.canonical)})

    def do_POST(self):
        if not self.allowed(): return
        if self.path not in ('/v1/audio/speech', '/v1/audio/preload', '/v1/audio/cancel'):
            self.send_error(404); return
        request_id = None; acquired = False; began = False
        try:
            value = self.read_json()
            if self.path.endswith('/cancel'):
                request_id = str(uuid.UUID(value['request_id']))
                self.server.cancel(request_id); self.json_reply(200, {'status': 'cancelled'}); return
            request_id = str(uuid.UUID(self.headers.get('X-Castor-Request-ID') or str(uuid.uuid4())))
            acquired = self.server.limit.acquire(blocking=False)
            if not acquired:
                self.json_reply(429, {'error': 'Busy'}); return
            cancelled = self.server.begin(request_id); began = True
            if self.path.endswith('/preload'):
                self.server.backend.preload(value['model'], cancelled)
                self.json_reply(200, {'status': 'ready', 'model': value['model']}); return
            payload = validated_payload(value)
            started = time.monotonic()
            data = self.server.backend.speech(payload, cancelled)
            if cancelled.is_set(): raise InterruptedError('Cancelled')
            self.send_response(200); self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Server-Timing', 'tts;dur=%.0f' % ((time.monotonic()-started)*1000))
            self.end_headers(); self.wfile.write(data)
        except InterruptedError:
            if began:
                self.server.finish(request_id); began = False
            self.json_reply(409, {'error': 'Cancelled'})
        except (ValueError, KeyError, TypeError):
            self.json_reply(400, {'error': 'Invalid request or unsupported model'})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            # Do not return local paths or model cache/environment details to clients.
            self.json_reply(503, {'error': 'Local speech model could not run'})
        finally:
            if acquired:
                if began: self.server.finish(request_id)
                self.server.limit.release()

    def log_message(self, format, *args):
        pass  # No conversation, image, local path or recording logs.


def model_is_ready(backend):
    """Read existing state only: no model acquisition, loading or audio work."""
    return bool(backend.alias) and not backend.loading


def launch_gui(start_on_open=False):
    import locale
    import tkinter as tk
    from tkinter import messagebox
    ja = (locale.getlocale()[0] or '').lower().startswith('ja')
    def label(japanese, english): return japanese if ja else english
    root = tk.Tk(); root.title('Castor Neural TTS'); root.geometry('560x390')
    server = None; prepare_cancel = threading.Event(); preparing = False
    status = tk.StringVar(value=label('停止中。モデルはまだ取得しません。', 'Stopped. No model download yet.'))
    tk.Label(root, text='Castor Neural TTS (Qwen)', font=('', 17, 'bold')).pack(pady=(20, 10))
    tk.Label(root, text=label('音声はこの端末で生成します。マイクの録音や声の複製は行いません。',
        'Speech is generated on this device. No microphone recording or voice cloning.'), wraplength=520).pack()
    tk.Label(root, textvariable=status, wraplength=500).pack(pady=12)
    def start():
        nonlocal server
        if server is not None: return
        try:
            server = SpeechServer(); threading.Thread(target=server.serve_forever, daemon=True).start()
            status.set(label('起動中。CastorのVoiceでNeural TTSを選べます。', 'Running. Select Neural TTS in Castor Voice settings.'))
        except OSError:
            server = None
            status.set(label('ポート8000を利用できません。既存helperが動いていないか確認してください。', 'Port 8000 is unavailable. Check whether another helper is running.'))
    def prepare():
        nonlocal preparing
        if preparing: return
        if not messagebox.askyesno('Castor', label('追加の大きな音声モデルを取得します。空き容量と時間が必要です。続けますか？',
            'Download the additional large speech model? This needs disk space and time.')): return
        start()
        if server is None: return
        preparing = True; prepare_cancel.clear()
        status.set(label('モデルを取得・準備しています。', 'Downloading and preparing the model.'))
        def work():
            nonlocal preparing
            try:
                server.backend.preload(DEFAULT_MODEL, prepare_cancel)
                result = label('モデルの準備ができました。', 'Model is ready.')
            except Exception:
                result = label('準備できませんでした。接続や空き容量を確認し、再試行してください。', 'Could not prepare. Check connection and disk space, then retry.')
            preparing = False
            try: root.after(0, lambda: status.set(result))
            except (RuntimeError, tk.TclError): pass
        threading.Thread(target=work, daemon=True).start()
    def close():
        prepare_cancel.set()
        if server:
            with server.jobs_lock:
                for event in server.jobs.values(): event.set()
            server.shutdown(); server.server_close()
        root.destroy()
    tk.Button(root, text=label('音声helperを起動', 'Start speech helper'), command=start, width=38).pack(pady=4)
    offer = tk.StringVar()
    offer_label = tk.Label(root, textvariable=offer, wraplength=520)
    offer_label.pack(pady=(10, 4))
    load_help = tk.Label(root, text=label('「ロード」を押すまでモデルを取得・読込しません。準備できるまでは標準音声を使えます。',
        'The model downloads / loads only when you press Load. System speech remains available.'), wraplength=520)
    load_help.pack()
    load_button = tk.Button(root, text=label('ロード', 'Load'), command=prepare, width=38)
    load_button.pack(pady=4)
    def refresh_offer():
        ready = server is not None and model_is_ready(server.backend)
        offer.set(label('✓ Qwen 3 TTSで話します（helper接続中）', '✓ Qwen 3 TTS is ready (helper connected)') if ready else label(
            '音声はQwen 3 TTSでよりリアルになります。ロードしますか？', 'Qwen 3 TTS can make speech more natural. Load it?'))
        load_button.configure(state='disabled' if ready or preparing else 'normal')
        load_help.configure(text='' if ready else label('「ロード」を押すまでモデルを取得・読込しません。準備できるまでは標準音声を使えます。',
            'The model downloads / loads only when you press Load. System speech remains available.'))
        root.after(500, refresh_offer)
    root.after(0, refresh_offer)
    tk.Button(root, text=label('停止して閉じる', 'Stop and close'), command=close, width=38).pack(pady=4)
    root.protocol('WM_DELETE_WINDOW', close)
    if start_on_open: root.after(0, start)
    root.mainloop()


def dependency_check(output):
    # Developer CI path: load the packaged dependencies without downloading a model.
    import importlib
    import importlib.metadata
    import platform
    from pathlib import Path
    result = {'ready': False, 'modelsLoaded': False, 'system': platform.system()}
    try:
        modules = ('mlx','mlx_audio','scipy','numpy','tkinter','transformers') if isinstance(default_backend(), MLXBackend) else ('torch','qwen_tts','numpy','librosa','soundfile','tkinter','accelerate','safetensors')
        for name in modules:
            importlib.import_module(name)
        result['ready'] = True
        result['versions'] = {name: importlib.metadata.version(name) for name in (('mlx-audio','mlx','numpy','transformers') if 'mlx' in modules else ('torch','qwen-tts','numpy','transformers'))}
    except Exception as error:
        result['errorType'] = type(error).__name__
    with Path(output).open('x', encoding='utf-8') as file: json.dump(result,file)
    return result['ready']


if __name__ == '__main__':
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == '--self-check':
        sys.exit(0 if dependency_check(sys.argv[2]) else 1)
    elif '--headless' in sys.argv: SpeechServer().serve_forever()
    else: launch_gui(start_on_open='--start' in sys.argv)
