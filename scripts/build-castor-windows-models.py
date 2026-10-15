#!/usr/bin/env python3
"""Add the Windows ML payload to a collected CastorPet runtime folder.

    python scripts/build-castor-windows-models.py --app DIR [--runtime-zip ZIP]

Writes DIR/models/*.onnx (ONNX exports of the Mac's anime face, landmark and
segmentation models), DIR/onnxruntime*.dll and DIR/licenses/onnxruntime-*.
The face weights are pinned to the Hub revisions and hashes of the verified
exports; the segmentation exporter pins its own; ONNX Runtime is the official
1.30.0 x64 archive, checked by hash. Needs torch, torchvision, onnx,
onnxruntime and anime-face-detector==0.1.0. Nothing is uploaded.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FACE_WEIGHTS = {
    'hysts/anime-face-detector-faster-rcnn': (
        'f64ed6a45f6e0da561ee4e4e69f25e1d9a01fe55', 'bf3093cc70aaeee6a0a45459aa5d724f9e74022b927b41ba364aac25adc8b009'),
    'hysts/anime-face-detector-hrnetv2': (
        '9b3435248b26aeb82e2a8578fe9d86d5d57158af', 'e71271376406a743c01528a0460637fcc06e72aeeea583f85007cc72dc8b7a4a'),
}
RUNTIME_URL = 'https://github.com/microsoft/onnxruntime/releases/download/v1.30.0/onnxruntime-win-x64-1.30.0.zip'
RUNTIME_SHA256 = 'c6ba983baf5681af108599675d2a89c2d145512d02de28aed0bff177cd0ba949'
RUNTIME_PREFIX = 'onnxruntime-win-x64-1.30.0/'
RUNTIME_FILES = {
    'lib/onnxruntime.dll': 'onnxruntime.dll',
    'lib/onnxruntime_providers_shared.dll': 'onnxruntime_providers_shared.dll',
    'LICENSE': 'licenses/onnxruntime-1.30.0-LICENSE.txt',
    'ThirdPartyNotices.txt': 'licenses/onnxruntime-1.30.0-ThirdPartyNotices.txt',
}
MODEL_NAMES = ('AnimeFaceFeatures', 'AnimeFaceBoxHead', 'AnimeFaceLandmarks', 'AnimeSegmentation')
#: SHA-256 of the exports whose parity with PyTorch and the shipped Core ML
#: models was measured (torch 2.14.1, onnx 1.23.2). Another toolchain may
#: write different bytes for the same network; that is reported, not fatal.
VERIFIED_EXPORTS = {
    'AnimeFaceFeatures': '024b53b0d315963b',
    'AnimeFaceBoxHead': 'dd7ca5c6f0cdc261',
    'AnimeFaceLandmarks': 'c7cddd9683bc6f80',
    'AnimeSegmentation': '2ddfe236fb7f9e8a',
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as file:
        for block in iter(lambda: file.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pin_face_weights():
    """anime-face-detector downloads the Hub's latest weights; hold it to the verified ones."""
    import anime_face_detector.detector as detector
    download = detector.hf_hub_download

    def pinned(repo_id, filename, **kwargs):
        if repo_id not in FACE_WEIGHTS:
            raise ValueError(f'Unexpected face model repository: {repo_id}')
        revision, expected = FACE_WEIGHTS[repo_id]
        kwargs['revision'] = revision
        path = download(repo_id, filename, **kwargs)
        if sha256(path) != expected:
            raise ValueError(f'{repo_id} weights do not match the verified export.')
        return path
    detector.hf_hub_download = pinned


def export_models(app):
    out = app/'models'
    out.mkdir()
    pin_face_weights()
    face = load(ROOT/'Arils/Tools/AnimeFaceModels/export_onnx.py', 'castor_face_onnx')
    face.export_all(out)
    segmentation = load(ROOT/'Arils/Tools/AnimeSegmentationModel/export_onnx.py', 'castor_segmentation_onnx')
    segmentation.export(segmentation.coreml_export.load_network(), out/'AnimeSegmentation.onnx')
    names = sorted(p.name for p in out.iterdir())
    if names != sorted(f'{name}.onnx' for name in MODEL_NAMES):
        raise ValueError(f'Unexpected model files: {names}')
    import onnxruntime
    for name in MODEL_NAMES:
        path = out/f'{name}.onnx'
        onnxruntime.InferenceSession(str(path), providers=['CPUExecutionProvider'])
        same = sha256(path).startswith(VERIFIED_EXPORTS[name])
        print(f'[models] {name}.onnx  {path.stat().st_size / 1e6:.1f} MB  '
              + ('identical to the parity-tested export' if same else 'differs from the parity-tested export; re-run parity'))


def add_runtime(app, archive):
    with tempfile.TemporaryDirectory() as scratch:
        if archive is None:
            archive = Path(scratch)/'onnxruntime.zip'
            with urllib.request.urlopen(RUNTIME_URL) as response, open(archive, 'wb') as file:
                shutil.copyfileobj(response, file)
        if sha256(archive) != RUNTIME_SHA256:
            raise ValueError('The ONNX Runtime archive does not match the pinned 1.30.0 release.')
        with zipfile.ZipFile(archive) as z:
            for source, target in RUNTIME_FILES.items():
                destination = app/target
                destination.parent.mkdir(parents=True, exist_ok=True)
                with z.open(RUNTIME_PREFIX + source) as reader, open(destination, 'wb') as writer:
                    shutil.copyfileobj(reader, writer)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True, help='Collected CastorPet runtime folder')
    parser.add_argument('--runtime-zip', type=Path, help='Already downloaded onnxruntime-win-x64-1.30.0.zip')
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app/'CastorPet.exe').is_file():
        parser.error('Expected a folder with CastorPet.exe.')
    if (app/'models').exists() or (app/'onnxruntime.dll').exists():
        parser.error('The folder already has a model payload.')
    try:
        add_runtime(app, args.runtime_zip)
        export_models(app)
    except (OSError, ValueError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    print(f'Added the Windows ML payload to {app}. Nothing was uploaded.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
