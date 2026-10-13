#!/usr/bin/env python3
"""Export the anime character segmentation model (ISNet) to Core ML.

Weights: `skytnt/anime-seg` on the Hugging Face Hub (Apache License 2.0),
`model.safetensors` at the pinned revision below. Network definition:
`model/isnet.py` from github.com/SkyTNT/anime-segmentation (Apache License
2.0) at the pinned commit. Both are downloaded into `build/` and never
committed; Core ML is one export of them, not the source of truth.

One model comes out:

    AnimeSegmentation   letterboxed RGB in 0...1, (1,3,1024,1024)
                        -> character probability (1,1,1024,1024), sigmoid applied

The letterboxing (aspect fit, centred, zero padding) and the resize back to
the source size live in Swift (ArilsSubjectInference), mirroring the
upstream `inference.py`.

    python3 export_coreml.py                       # writes .mlpackage + .mlmodelc
    python3 export_coreml.py --parity IMAGES...    # also compares Core ML with PyTorch

Requires: torch, torchvision, coremltools>=8, numpy, Pillow. The safetensors
file is parsed directly (no pickle), so the `safetensors` package is not needed.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import shutil
import struct
import subprocess
import sys

import numpy as np
import torch
from torch import nn

WEIGHTS_REVISION = "493cb60893f47441b26ec4fb9a306bce9e342982"
WEIGHTS_URL = f"https://huggingface.co/skytnt/anime-seg/resolve/{WEIGHTS_REVISION}/model.safetensors"
WEIGHTS_SHA256 = "3351563ba8b61a01a66bacb79cf36aabce2da62d88b7606a719f573f23fe5d3e"
SOURCE_COMMIT = "52906be5c171b90b34478cb35cedb6203bc86127"
SOURCE_URL = f"https://raw.githubusercontent.com/SkyTNT/anime-segmentation/{SOURCE_COMMIT}/model/isnet.py"
INPUT_SIZE = 1024

TOOL_DIR = pathlib.Path(__file__).resolve().parent
BUILD = TOOL_DIR / "build"
DEFAULT_OUT = TOOL_DIR.parents[1] / "Sources/ArilsSubjectInference/Resources/AnimeSegmentationModel"


def fetch(url: str, path: pathlib.Path, sha256: str | None = None) -> pathlib.Path:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"downloading {url}")
        # curl uses the system trust store; python.org builds of Python
        # often ship without one, which makes urllib fail on HTTPS.
        subprocess.run(["curl", "-sSfL", "-o", str(path), url], check=True)
    if sha256:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != sha256:
            raise SystemExit(f"{path.name}: sha256 {digest} != pinned {sha256}")
    return path


def load_safetensors(path: pathlib.Path) -> dict[str, torch.Tensor]:
    data = path.read_bytes()
    header_length = struct.unpack("<Q", data[:8])[0]
    header = json.loads(data[8:8 + header_length])
    base = 8 + header_length
    dtypes = {"F32": np.float32, "F16": np.float16, "I64": np.int64}
    tensors = {}
    for key, info in header.items():
        if key == "__metadata__":
            continue
        start, end = info["data_offsets"]
        array = np.frombuffer(data[base + start:base + end], dtype=dtypes[info["dtype"]])
        tensors[key] = torch.from_numpy(array.reshape(info["shape"]).copy())
    return tensors


def load_network() -> nn.Module:
    source = fetch(SOURCE_URL, BUILD / f"isnet-{SOURCE_COMMIT[:8]}.py")
    spec = importlib.util.spec_from_file_location("anime_isnet", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    weights = fetch(WEIGHTS_URL, BUILD / f"anime-seg-{WEIGHTS_REVISION[:8]}.safetensors", WEIGHTS_SHA256)
    state = load_safetensors(weights)
    net = module.ISNetDIS()
    net.load_state_dict({k[4:]: v for k, v in state.items() if k.startswith("net.")}, strict=True)
    return net.eval()


class Probability(nn.Module):
    """The upstream `AnimeSegmentation.forward` for ISNet: first side output, sigmoid."""

    def __init__(self, net: nn.Module):
        super().__init__()
        self.net = net

    def forward(self, x):
        return self.net(x)[0][0].sigmoid()


def letterbox(image: np.ndarray, size: int = INPUT_SIZE):
    """Upstream `get_mask` preprocessing (aspect fit, centred, zero pad)."""
    from PIL import Image

    h0, w0 = image.shape[:2]
    h, w = (size, int(size * w0 / h0)) if h0 > w0 else (int(size * h0 / w0), size)
    resized = np.asarray(Image.fromarray(image).resize((w, h), Image.BILINEAR), dtype=np.float32) / 255
    canvas = np.zeros((size, size, 3), np.float32)
    top, left = (size - h) // 2, (size - w) // 2
    canvas[top:top + h, left:left + w] = resized
    return canvas.transpose(2, 0, 1)[None], (top, left, h, w)


def convert(net: nn.Module, precision: str):
    import coremltools as ct

    wrapper = Probability(net).eval()
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE)
    traced = torch.jit.trace(wrapper, example)
    return ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=example.shape)],
        outputs=[ct.TensorType(name="probability")],
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )


def compile_model(package: pathlib.Path, out: pathlib.Path) -> pathlib.Path:
    out.mkdir(parents=True, exist_ok=True)
    compiled = out / (package.stem + ".mlmodelc")
    if compiled.exists():
        shutil.rmtree(compiled)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True,
                   stdout=subprocess.DEVNULL)
    return compiled


def parity(net: nn.Module, model, images: list[str]) -> None:
    from PIL import Image

    for path in images:
        rgb = np.asarray(Image.open(path).convert("RGB"))
        tensor, _ = letterbox(rgb)
        with torch.no_grad():
            reference = Probability(net)(torch.from_numpy(tensor)).numpy()
        predicted = model.predict({"image": tensor})["probability"]
        difference = np.abs(predicted - reference)
        agreement = ((predicted > 0.5) == (reference > 0.5)).mean()
        print(f"{pathlib.Path(path).name}: mean |Δ| {difference.mean():.5f}, "
              f"max |Δ| {difference.max():.4f}, mask agreement {agreement:.5f}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT)
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    parser.add_argument("--parity", nargs="*", default=[], metavar="IMAGE")
    args = parser.parse_args()

    net = load_network()
    model = convert(net, args.precision)
    package = BUILD / "AnimeSegmentation.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    model.save(str(package))
    compiled = compile_model(package, args.out)
    print(f"wrote {package} and {compiled}")
    if args.parity:
        parity(net, model, args.parity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
