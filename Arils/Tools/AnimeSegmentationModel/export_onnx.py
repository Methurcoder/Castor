#!/usr/bin/env python3
"""Export the anime character segmentation model (ISNet) to ONNX for Windows.

Same weights, network and pre/post-processing contract as export_coreml.py:
input `image` (1,3,1024,1024) RGB in 0...1, letterboxed (aspect fit, centred,
zero padding); output `probability` (1,1,1024,1024), the sigmoid of the
first side output. The Swift side (ArilsSubjectInference) does the letterbox
and the resize back, so Core ML and ONNX Runtime receive identical tensors.

    python3 export_onnx.py                      # writes build/AnimeSegmentation.onnx
    python3 export_onnx.py --parity IMAGES...   # compares ONNX Runtime with PyTorch
                                                # and with the shipped Core ML model

Requires: torch, numpy, Pillow, onnx, onnxruntime (coremltools for the Core ML
comparison, macOS only).
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys

import numpy as np
import torch

TOOL_DIR = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("export_coreml", TOOL_DIR / "export_coreml.py")
coreml_export = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(coreml_export)

DEFAULT_OUT = coreml_export.BUILD / "AnimeSegmentation.onnx"
SHIPPED_COREML = coreml_export.DEFAULT_OUT / "AnimeSegmentation.mlmodelc"


def export(net: torch.nn.Module, out: pathlib.Path) -> pathlib.Path:
    wrapper = coreml_export.Probability(net).eval()
    example = torch.zeros(1, 3, coreml_export.INPUT_SIZE, coreml_export.INPUT_SIZE)
    out.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        wrapper, (example,), str(out),
        input_names=["image"], output_names=["probability"],
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    import onnx
    onnx.checker.check_model(str(out))
    return out


def parity(net: torch.nn.Module, onnx_path: pathlib.Path, images: list[str]) -> None:
    import onnxruntime as ort
    from PIL import Image

    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    coreml = None
    if SHIPPED_COREML.exists() and sys.platform == "darwin":
        import coremltools as ct
        coreml = ct.models.CompiledMLModel(str(SHIPPED_COREML), compute_units=ct.ComputeUnit.CPU_ONLY)
    wrapper = coreml_export.Probability(net).eval()
    for path in images:
        rgb = np.asarray(Image.open(path).convert("RGB"))
        tensor, _ = coreml_export.letterbox(rgb)
        with torch.no_grad():
            reference = wrapper(torch.from_numpy(tensor)).numpy()
        onnx_out = session.run(["probability"], {"image": tensor})[0]
        line = (f"{pathlib.Path(path).name}: ONNX vs PyTorch max |Δ| {np.abs(onnx_out - reference).max():.5f}, "
                f"mask agreement {((onnx_out > 0.5) == (reference > 0.5)).mean():.5f}")
        if coreml is not None:
            shipped = coreml.predict({"image": tensor})["probability"]
            line += (f" | ONNX vs shipped Core ML mean |Δ| {np.abs(onnx_out - shipped).mean():.5f}, "
                     f"mask agreement {((onnx_out > 0.5) == (shipped > 0.5)).mean():.5f}")
        print(line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT)
    parser.add_argument("--parity", nargs="*", default=[], metavar="IMAGE")
    args = parser.parse_args()
    net = coreml_export.load_network()
    path = export(net, args.out)
    print(f"wrote {path} ({path.stat().st_size / 1e6:.1f} MB)")
    if args.parity:
        parity(net, path, args.parity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
