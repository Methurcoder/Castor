#!/usr/bin/env python3
"""Export the anime face detector and landmark model to ONNX for Windows.

The same networks, wrappers and three-model contract as export_coreml.py
(they are imported from it), so the Swift post-processing in
ArilsFaceInference (anchors, NMS, RoIAlign, heatmap decoding) is shared
between Core ML on the Mac and ONNX Runtime on Windows:

    AnimeFaceFeatures   image (1,3,H,W), H and W multiples of 32
                        -> p2..p5, rpn_score0..4, rpn_delta0..4
    AnimeFaceBoxHead    roi_features (N,256,7,7) -> class_logits, box_deltas
    AnimeFaceLandmarks  crop (1,3,256,256) -> heatmaps (1,28,64,64), flip-averaged

    python3 export_onnx.py                   # writes build/*.onnx
    python3 export_onnx.py --parity IMAGES   # compares with the shipped Core ML models

Requires: anime-face-detector==0.1.0 (pure PyTorch), torch, onnx, onnxruntime;
coremltools for the comparison (macOS only).
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

BUILD = coreml_export.DEFAULT_PACKAGES
SHIPPED = coreml_export.DEFAULT_OUT
FEATURE_NAMES = [f"p{i}" for i in range(2, 6)] + [f"rpn_score{i}" for i in range(5)] + [f"rpn_delta{i}" for i in range(5)]
#: mmdet's default normalization, applied in Swift before either runtime.
MEAN, STD = np.array([123.675, 116.28, 103.53]), np.array([58.395, 57.12, 57.375])


def modules():
    from anime_face_detector import create_detector
    from anime_face_detector._landmark import FLIP_PAIRS

    detector = create_detector("faster-rcnn", device="cpu")
    faster_rcnn = detector.face_detector
    return {
        "AnimeFaceFeatures": (coreml_export.Features(faster_rcnn), torch.zeros(1, 3, 800, 1216), ["image"],
                              FEATURE_NAMES, {"image": {2: "height", 3: "width"}}),
        "AnimeFaceBoxHead": (coreml_export.BoxHead(faster_rcnn), torch.zeros(4, 256, 7, 7), ["roi_features"],
                             ["class_logits", "box_deltas"],
                             {"roi_features": {0: "rois"}, "class_logits": {0: "rois"}, "box_deltas": {0: "rois"}}),
        "AnimeFaceLandmarks": (coreml_export.Landmarks(detector.landmark_detector, FLIP_PAIRS),
                               torch.zeros(1, 3, 256, 256), ["crop"], ["heatmaps"], None),
    }


def export_all(out: pathlib.Path) -> None:
    import onnx

    out.mkdir(parents=True, exist_ok=True)
    for name, (module, example, inputs, outputs, axes) in modules().items():
        path = out / f"{name}.onnx"
        torch.onnx.export(module.eval(), (example,), str(path), input_names=inputs, output_names=outputs,
                          dynamic_axes=axes, opset_version=17, do_constant_folding=True, dynamo=False)
        onnx.checker.check_model(str(path))
        print(f"[export] {path.name}  {path.stat().st_size / 1e6:.1f} MB")


def parity(out: pathlib.Path, image_paths: list[str]) -> None:
    """ONNX Runtime vs the shipped Core ML models (fp16) on real, normalized inputs."""
    import coremltools as ct
    import onnxruntime as ort
    from PIL import Image

    def rel(a, b):
        return float(np.abs(a - b).max() / (np.abs(b).max() + 1e-6))

    def run_both(name, feeds):
        session = ort.InferenceSession(str(out / f"{name}.onnx"), providers=["CPUExecutionProvider"])
        coreml = ct.models.CompiledMLModel(str(SHIPPED / f"{name}.mlmodelc"), compute_units=ct.ComputeUnit.CPU_ONLY)
        return session.run(None, feeds), coreml.predict(feeds)

    def normalized(path, size):
        rgb = np.asarray(Image.open(path).convert("RGB").resize(size), dtype=np.float32)
        return ((rgb - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)

    for path in image_paths:
        features, coreml_features = run_both("AnimeFaceFeatures", {"image": normalized(path, (608, 800))})
        worst = max(rel(o, coreml_features[n]) for o, n in zip(features, FEATURE_NAMES))
        rois = np.ascontiguousarray(features[0][:, :, 40:47, 40:47].repeat(5, axis=0))
        box, coreml_box = run_both("AnimeFaceBoxHead", {"roi_features": rois})
        box_error = max(rel(box[0], coreml_box["class_logits"]), rel(box[1], coreml_box["box_deltas"]))
        heat, coreml_heat = run_both("AnimeFaceLandmarks", {"crop": normalized(path, (256, 256))})
        a, b = heat[0][0], coreml_heat["heatmaps"][0]
        same_peak = np.mean([np.unravel_index(a[k].argmax(), a[k].shape) == np.unravel_index(b[k].argmax(), b[k].shape)
                             for k in range(28)])
        print(f"{pathlib.Path(path).name}: features max rel Δ {worst:.4f}, box head {box_error:.4f}, "
              f"heatmaps {rel(a, b):.4f}, same landmark peak {same_peak:.3f}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, default=BUILD)
    parser.add_argument("--parity", nargs="*", default=None, metavar="IMAGE")
    args = parser.parse_args()
    export_all(args.out)
    if args.parity is not None:
        parity(args.out, args.parity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
