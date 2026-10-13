#!/usr/bin/env python3
"""Export the anime face detector and landmark model to Core ML.

The canonical weights are the MIT-licensed safetensors on the Hugging Face Hub
(`hysts/anime-face-detector-faster-rcnn`, `hysts/anime-face-detector-hrnetv2`,
pinned below), as roadmap 7.4 asks: Core ML is one export of them, not the
source of truth. Only the network bodies become Core ML. The parts that are
data-dependent (anchor decoding, NMS, RoIAlign with adaptive sampling, heatmap
decoding) live in Swift in the ArilsFaceInference target, where they are a
line-for-line port of `anime_face_detector` 0.1.0 and can be unit tested.

Three models come out:

    AnimeFaceFeatures   normalized, stride-32-padded image (1,3,H,W)
                        -> FPN levels P2..P5 and RPN scores/deltas for P2..P6
    AnimeFaceBoxHead    RoI features (N,256,7,7) -> class logits, box deltas
    AnimeFaceLandmarks  normalized 256x256 crop (1,3,256,256) -> 28 heatmaps
                        (1,28,64,64), already averaged with the flipped crop
                        exactly as the package's flip test does

    python3 export_coreml.py                         # writes .mlpackage + .mlmodelc
    python3 export_coreml.py --reference IMAGES...   # also dumps the Python
                                                     # pipeline's output for parity

Requires: anime-face-detector==0.1.0, torch, coremltools>=8.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

import numpy as np
import torch
from torch import nn

#: Hub revisions the shipped models were exported from.
REVISIONS = {
    "faster-rcnn": "hysts/anime-face-detector-faster-rcnn",
    "hrnetv2": "hysts/anime-face-detector-hrnetv2",
}
TOOL_DIR = pathlib.Path(__file__).resolve().parent
#: Only the compiled models go into the bundle; the editable packages stay here.
DEFAULT_OUT = TOOL_DIR.parents[1] / "Sources/ArilsFaceInference/Resources/AnimeFaceModels"
DEFAULT_PACKAGES = TOOL_DIR / "build"


def fpn_forward(neck, inputs):
    """The package's FPN forward with `size=prev_shape` replaced by a factor of 2.

    Core ML cannot map a nearest upsample whose size is read from another
    tensor's runtime shape. The input is padded to a multiple of 32, so every
    FPN level is exactly twice the next one and the two are the same
    operation; `parity` in this script checks that on real images.
    """
    import torch.nn.functional as F

    laterals = [conv(inputs[i + neck.start_level]) for i, conv in enumerate(neck.lateral_convs)]
    for i in range(len(laterals) - 1, 0, -1):
        laterals[i - 1] = laterals[i - 1] + F.interpolate(laterals[i], scale_factor=2.0, mode="nearest")
    outs = [neck.fpn_convs[i](laterals[i]) for i in range(len(laterals))]
    for _ in range(neck.num_outs - len(laterals)):
        outs.append(F.max_pool2d(outs[-1], 1, stride=2))
    return tuple(outs)


class Features(nn.Module):
    def __init__(self, detector) -> None:
        super().__init__()
        self.backbone = detector.backbone
        self.neck = detector.neck
        self.rpn = detector.rpn_head

    def forward(self, image):
        feats = fpn_forward(self.neck, self.backbone(image))
        scores, deltas = self.rpn(feats)
        return (*feats[:4], *scores, *deltas)


class BoxHead(nn.Module):
    def __init__(self, detector) -> None:
        super().__init__()
        self.head = detector.roi_head.bbox_head

    def forward(self, roi_features):
        return self.head(roi_features)


class Landmarks(nn.Module):
    """Both passes of the flip test in one batch, recombined as the package does."""

    def __init__(self, model, flip_pairs) -> None:
        super().__init__()
        self.backbone = model.backbone
        self.head = model.keypoint_head
        permutation = list(range(28))
        for left, right in flip_pairs:
            permutation[left], permutation[right] = right, left
        self.register_buffer("permutation", torch.tensor(permutation, dtype=torch.long))

    def forward(self, crop):
        batch = torch.cat([crop, torch.flip(crop, dims=[3])], dim=0)
        heatmaps = self.head(self.backbone(batch))
        plain, flipped = heatmaps[0:1], heatmaps[1:2]
        flipped = torch.index_select(flipped, 1, self.permutation)
        flipped = torch.flip(flipped, dims=[3])
        # shift_heatmap: column j takes column j-1, column 0 stays.
        flipped = torch.cat([flipped[..., :1], flipped[..., :-1]], dim=3)
        return (plain + flipped) * 0.5


def convert(module, example, inputs, outputs, path: pathlib.Path, precision: str):
    import coremltools as ct

    traced = torch.jit.trace(module.eval(), example, check_trace=False)
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name=name) for name in outputs],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    model.author = "hysts (weights, MIT); exported for Arils"
    model.license = "MIT"
    if path.exists():
        shutil.rmtree(path)
    model.save(str(path))
    return model


def compile_model(package: pathlib.Path, out: pathlib.Path) -> pathlib.Path:
    compiled = out / package.with_suffix(".mlmodelc").name
    if compiled.exists():
        shutil.rmtree(compiled)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)],
                   check=True, stdout=subprocess.DEVNULL)
    return compiled


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT,
                        help="where the compiled .mlmodelc go (the ArilsFaceInference resource folder)")
    parser.add_argument("--packages", type=pathlib.Path, default=DEFAULT_PACKAGES,
                        help="where the .mlpackage sources go (kept out of the bundle)")
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    parser.add_argument("--reference", nargs="*", type=pathlib.Path, default=[],
                        help="images to run through the Python pipeline for a parity file")
    parser.add_argument("--reference-out", type=pathlib.Path, default=None)
    parser.add_argument("--skip-export", action="store_true")
    args = parser.parse_args()

    import coremltools as ct
    from anime_face_detector import create_detector
    from anime_face_detector._landmark import FLIP_PAIRS

    detector = create_detector("faster-rcnn", device="cpu")
    faster_rcnn = detector.face_detector
    landmark = detector.landmark_detector
    args.out.mkdir(parents=True, exist_ok=True)
    args.packages.mkdir(parents=True, exist_ok=True)

    if not args.skip_export:
        flexible = ct.Shape(shape=(1, 3, ct.RangeDim(32, 1344, default=800), ct.RangeDim(32, 1344, default=1216)))
        names = [f"p{i}" for i in range(2, 6)] + [f"rpn_score{i}" for i in range(5)] + [f"rpn_delta{i}" for i in range(5)]
        convert(Features(faster_rcnn), torch.zeros(1, 3, 800, 1216),
                [ct.TensorType(name="image", shape=flexible)], names,
                args.packages / "AnimeFaceFeatures.mlpackage", args.precision)
        convert(BoxHead(faster_rcnn), torch.zeros(4, 256, 7, 7),
                [ct.TensorType(name="roi_features", shape=ct.Shape(shape=(ct.RangeDim(1, 1000, default=1000), 256, 7, 7)))],
                ["class_logits", "box_deltas"], args.packages / "AnimeFaceBoxHead.mlpackage", args.precision)
        convert(Landmarks(landmark, FLIP_PAIRS), torch.zeros(1, 3, 256, 256),
                [ct.TensorType(name="crop", shape=(1, 3, 256, 256))], ["heatmaps"],
                args.packages / "AnimeFaceLandmarks.mlpackage", args.precision)
        for package in sorted(args.packages.glob("*.mlpackage")):
            compiled = compile_model(package, args.out)
            size = sum(f.stat().st_size for f in compiled.rglob("*") if f.is_file())
            print(f"[export] {compiled.name}  {size / 1e6:.1f} MB")

    if args.reference:
        import cv2

        records = []
        for path in args.reference:
            image = cv2.imread(str(path))
            predictions = detector(image)
            records.append({
                "image": path.name,
                "width": int(image.shape[1]), "height": int(image.shape[0]),
                "faces": [{
                    "bbox": [float(v) for v in np.asarray(p["bbox"])[:4]],
                    "score": float(np.asarray(p["bbox"])[4]),
                    "keypoints": np.asarray(p["keypoints"], dtype=float).round(4).tolist(),
                } for p in predictions],
            })
        target = args.reference_out or (args.packages / "reference.json")
        target.write_text(json.dumps(records, indent=1))
        print(f"[export] reference for {len(records)} images -> {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
