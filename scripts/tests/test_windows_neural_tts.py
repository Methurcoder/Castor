import importlib.util
import io
import json
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.request
import uuid
import wave

SPEC = importlib.util.spec_from_file_location('castor_windows_tts', Path(__file__).parents[1]/'windows_neural_tts_server.py')
TTS = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(TTS)

class FakeBackend:
    alias = None; canonical = None; loading = False
    def preload(self, alias, cancelled):
        if cancelled.is_set(): raise InterruptedError()
        self.alias = alias; self.canonical = TTS.MODELS[alias]
    def speech(self, payload, cancelled):
        if cancelled.is_set(): raise InterruptedError()
        self.preload(payload['model'], cancelled)
        data = io.BytesIO()
        with wave.open(data, 'wb') as writer:
            writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(24000); writer.writeframes(b'\0\0'*240)
        return data.getvalue()

class NeuralServerTests(unittest.TestCase):
    def setUp(self):
        self.server = TTS.SpeechServer(('127.0.0.1', 0), FakeBackend())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_address[1]
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
    def post(self, path, value, headers=None):
        req = urllib.request.Request(self.base+path, data=json.dumps(value).encode(), headers={'Content-Type':'application/json', **(headers or {})})
        return urllib.request.urlopen(req, timeout=3)
    def test_idle_then_shared_payload_returns_wav(self):
        with urllib.request.urlopen(self.base+'/v1/audio/status') as response:
            self.assertIsNone(json.load(response)['model'])
        with self.post('/v1/audio/speech', {'input':'hello','voice':'Ryan','lang_code':'en','speed':1}) as response:
            with wave.open(io.BytesIO(response.read())) as audio:
                self.assertEqual(audio.getframerate(),24000); self.assertEqual(audio.getnframes(),240)
    def test_origin_and_arbitrary_model_are_rejected(self):
        for payload, headers, expected in [({'input':'hello'}, {'Origin':'https://example.com'},403),
                                          ({'input':'hello','model':'unknown/model'}, {},400)]:
            with self.assertRaises(urllib.error.HTTPError) as error: self.post('/v1/audio/speech',payload,headers)
            self.assertEqual(error.exception.code,expected)
    def test_cancel_before_start_is_honored(self):
        request_id = str(uuid.uuid4())
        with self.post('/v1/audio/cancel',{'request_id':request_id}): pass
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('/v1/audio/speech',{'input':'hello'}, {'X-Castor-Request-ID':request_id})
        self.assertEqual(error.exception.code,409)
        self.assertEqual(self.server.jobs,{})
    def test_duplicate_id_does_not_remove_existing_job(self):
        request_id = str(uuid.uuid4()); event = self.server.begin(request_id)
        with self.assertRaises(urllib.error.HTTPError):
            self.post('/v1/audio/speech',{'input':'hello'}, {'X-Castor-Request-ID':request_id})
        self.assertIs(self.server.jobs[request_id],event)
        self.server.cancel(request_id); self.assertTrue(event.is_set())
    def test_payload_limits_and_language_contract(self):
        for payload in [{'input':''},{'input':'ok','speed':float('nan')},{'input':'ok','stream':True},
                        {'input':'ok','lang_code':'invalid'},{'input':'ok','response_format':'mp3'}]:
            with self.assertRaises(ValueError): TTS.validated_payload(payload)
        self.assertEqual(TTS.validated_payload({'input':'hello','lang_code':'JA'})['lang_code'],'ja')
    def test_server_cannot_bind_external_interface(self):
        with self.assertRaises(ValueError): TTS.SpeechServer(('0.0.0.0',0),FakeBackend())

if __name__ == '__main__': unittest.main()
