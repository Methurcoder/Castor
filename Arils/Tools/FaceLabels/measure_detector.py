#!/usr/bin/env python3
"""Measure an anime face detector against the hand-verified labels.

The question is narrow: can `hysts/anime-face-detector` place the eye and
mouth rectangles that `PartPlan` needs, well enough to pre-label images so a
person only has to confirm them? The answer has to be a number, because the
last attempt at automatic labelling was wrong by a constant offset and nobody
noticed until a model trained on it collapsed.

So this compares, per part, against `arils_manual_annotations.json`:

    IoU  intersection over union with the hand-drawn box
    and the same measurement for the estimator Arils ships today, so the
    comparison is against the real baseline rather than against nothing.

It also settles the left/right convention empirically instead of trusting a
docstring. `FaceLayout` says "left" means the *viewer's* left; the detector's
landmark indices might follow either convention, and getting it backwards is
exactly the silent failure that has to be ruled out. Both mappings are scored
and the better one is reported.

Landmark layout (28 points, from the model card):
    0-4 face bottom outline, 5-7 / 8-10 eyebrows,
    11-16 one eye, 17-22 the other eye, 23 nose, 24-27 mouth outline

Usage:
    python3 measure_detector.py [--dataset ~/開発/Pomegranate/Arils_Dataset]
                                [--detector faster-rcnn] [--device cpu]
                                [--out DIR]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

import numpy as np

EYE_A = list(range(11, 17))
EYE_B = list(range(17, 23))
MOUTH = list(range(24, 28))
OUTLINE = list(range(0, 5))
BROW_A = list(range(5, 8))
BROW_B = list(range(8, 11))


def box_from(points: np.ndarray, indices: list[int]) -> dict:
    selected = points[indices][:, :2]
    x0, y0 = selected.min(axis=0)
    x1, y1 = selected.max(axis=0)
    return {"x": float(x0), "y": float(y0), "width": float(x1 - x0), "height": float(y1 - y0)}


def iou(a: dict, b: dict) -> float:
    ax2, ay2 = a["x"] + a["width"], a["y"] + a["height"]
    bx2, by2 = b["x"] + b["width"], b["y"] + b["height"]
    ix = max(0.0, min(ax2, bx2) - max(a["x"], b["x"]))
    iy = max(0.0, min(ay2, by2) - max(a["y"], b["y"]))
    inter = ix * iy
    union = a["width"] * a["height"] + b["width"] * b["height"] - inter
    return inter / union if union > 0 else 0.0


def centre_error(a: dict, b: dict, diagonal: float) -> float:
    ax, ay = a["x"] + a["width"] / 2, a["y"] + a["height"] / 2
    bx, by = b["x"] + b["width"] / 2, b["y"] + b["height"] / 2
    return float(np.hypot(ax - bx, ay - by) / max(diagonal, 1e-6))


def to_top_left(box: dict) -> dict:
    """Annotation boxes store the CENTRE, not the corner.

    This is the CreateML convention, the same one `CreateMLCoordinates` in
    Tools/ArilsCorpus converts with `x - width * 0.5`. It was verified against
    the two images where the shipped estimator is known to be right: reading
    the stored x,y as a corner puts the head box 0.17 away from the estimator's,
    reading it as a centre puts it 0.01 away. Getting this backwards silently
    destroys every measurement, which is why it is asserted here rather than
    assumed at the call site.
    """
    return {
        "x": box["x"] - box["width"] / 2,
        "y": box["y"] - box["height"] / 2,
        "width": box["width"],
        "height": box["height"],
    }


def manual_boxes(entry: dict) -> dict[str, dict] | None:
    faces = entry["annotation"].get("faces") or []
    if not faces:
        return None
    parts = faces[0].get("parts") or {}
    out = {}
    for name in ("head", "eyeLeft", "eyeRight", "mouth", "neck"):
        part = parts.get(name) or {}
        box = part.get("box")
        if box and box.get("width"):
            out[name] = to_top_left(box)
    return out or None


def summarise(values: list[float]) -> str:
    if not values:
        return "n/a"
    array = np.array(values)
    return f"mean {array.mean():.3f}  median {np.median(array):.3f}  min {array.min():.3f}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=pathlib.Path,
                        default=pathlib.Path.home() / "開発/Pomegranate/Arils_Dataset")
    parser.add_argument("--detector", default="faster-rcnn", choices=["faster-rcnn", "yolov3"])
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--out", type=pathlib.Path, default=None)
    parser.add_argument("--rules", default="latest",
                        help="which labels to measure against: 'latest' (only entries drawn to the newest "
                             "label rules, e.g. v2 from face_labeler.py), 'all', or a rules name")
    args = parser.parse_args()

    from anime_face_detector import create_detector

    annotations = json.loads((args.dataset / "arils_manual_annotations.json").read_text())["entries"]
    # Labels drawn to different rules disagree by construction (the v1 boxes
    # varied 16x in mouth height), so a fit over a mix measures the mix.
    rules_present = sorted({entry.get("labelRules", "v1") for entry in annotations})
    wanted = rules_present[-1] if args.rules == "latest" else args.rules
    if wanted != "all":
        annotations = [entry for entry in annotations if entry.get("labelRules", "v1") == wanted]
    print(f"label rules: {wanted} (present: {', '.join(rules_present)})")
    # Images whose label started from a detector draft. A person correcting a
    # draft can leave a box where the detector put it, which flatters the
    # detector, so these are reported apart from labels drawn without a draft.
    draft_path = args.dataset / "arils_draft_annotations.json"
    drafted = ({entry["image"] for entry in json.loads(draft_path.read_text())["entries"]}
               if draft_path.exists() else set())
    print(f"hand-verified entries: {len(annotations)}")
    print(f"detector: {args.detector} on {args.device}\n")

    started = time.time()
    detector = create_detector(face_detector_name=args.detector, device=args.device)
    print(f"loaded in {time.time() - started:.1f}s\n")

    from PIL import Image

    # Both readings of which landmark group is which eye.
    conventions = {"A=eyeLeft": (EYE_A, EYE_B), "B=eyeLeft": (EYE_B, EYE_A)}
    scores: dict[str, dict[str, list[float]]] = {
        name: {"eyeLeft": [], "eyeRight": []} for name in conventions
    }
    fit_inputs: dict[str, list[tuple[dict, dict]]] = {"eyeLeft": [], "eyeRight": [], "mouth": [], "head": [], "neck": []}
    fit_names: dict[str, list[str]] = {part: [] for part in fit_inputs}
    side_swapped: list[str] = []
    fitted_scores: dict[str, float] = {}
    mouth_iou: list[float] = []
    mouth_centre: list[float] = []
    head_iou_raw: list[float] = []
    face_to_head: list[tuple[float, float, float, float]] = []
    detected = 0
    missed: list[str] = []
    records: list[dict] = []

    for entry in annotations:
        name = entry["image"]
        path = args.dataset / name
        if not path.exists():
            path = args.dataset / "images" / pathlib.Path(name).name
        if not path.exists():
            missed.append(f"{name} (file not found)")
            continue
        manual = manual_boxes(entry)
        if manual is None:
            missed.append(f"{name} (no manual face)")
            continue

        with Image.open(path) as image:
            width, height = image.size
            array = np.asarray(image.convert("RGB"))[:, :, ::-1]  # detector expects BGR
        diagonal = float(np.hypot(1.0, 1.0))

        predictions = detector(np.ascontiguousarray(array))
        if not predictions:
            missed.append(f"{name} (no face detected)")
            records.append({"image": name, "detected": False})
            continue
        best = max(predictions, key=lambda p: float(np.asarray(p["bbox"])[4]))
        points = np.asarray(best["keypoints"], dtype=np.float32).copy()
        points[:, 0] /= width
        points[:, 1] /= height
        bbox = np.asarray(best["bbox"], dtype=np.float32)
        face = {
            "x": float(bbox[0] / width), "y": float(bbox[1] / height),
            "width": float((bbox[2] - bbox[0]) / width),
            "height": float((bbox[3] - bbox[1]) / height),
        }
        detected += 1

        record: dict = {"image": name, "detected": True, "faceScore": float(bbox[4])}
        for convention, (left_indices, right_indices) in conventions.items():
            left = box_from(points, left_indices)
            right = box_from(points, right_indices)
            if "eyeLeft" in manual:
                scores[convention]["eyeLeft"].append(iou(left, manual["eyeLeft"]))
            if "eyeRight" in manual:
                scores[convention]["eyeRight"].append(iou(right, manual["eyeRight"]))
            if convention == "A=eyeLeft":
                if "eyeLeft" in manual:
                    fit_inputs["eyeLeft"].append((left, manual["eyeLeft"]))
                    fit_names["eyeLeft"].append(name)
                if "eyeRight" in manual:
                    fit_inputs["eyeRight"].append((right, manual["eyeRight"]))
                    fit_names["eyeRight"].append(name)
                if "eyeLeft" in manual and "eyeRight" in manual:
                    # The landmark groups are the character's own eyes; the
                    # label is the viewer's. On a face lying sideways or upside
                    # down those disagree, and this is where it shows.
                    kept = iou(left, manual["eyeLeft"]) + iou(right, manual["eyeRight"])
                    crossed = iou(right, manual["eyeLeft"]) + iou(left, manual["eyeRight"])
                    if crossed > kept:
                        side_swapped.append(name)

        if "mouth" in manual:
            predicted_mouth = box_from(points, MOUTH)
            mouth_iou.append(iou(predicted_mouth, manual["mouth"]))
            mouth_centre.append(centre_error(predicted_mouth, manual["mouth"], diagonal))
            record["mouthIoU"] = mouth_iou[-1]
            fit_inputs["mouth"].append((predicted_mouth, manual["mouth"]))
            fit_names["mouth"].append(name)
        if "head" in manual:
            head = manual["head"]
            head_iou_raw.append(iou(face, head))
            record["headIoUvsFaceBox"] = head_iou_raw[-1]
            fit_inputs["head"].append((face, head))
            fit_names["head"].append(name)
        if "neck" in manual:
            fit_inputs["neck"].append((face, manual["neck"]))
            fit_names["neck"].append(name)
            # How the hand-drawn head box relates to the detected face box, so
            # a derived head rectangle can be fitted rather than guessed.
            face_to_head.append((
                (head["x"] + head["width"] / 2 - (face["x"] + face["width"] / 2)) / max(face["width"], 1e-6),
                (head["y"] + head["height"] / 2 - (face["y"] + face["height"] / 2)) / max(face["height"], 1e-6),
                head["width"] / max(face["width"], 1e-6),
                head["height"] / max(face["height"], 1e-6),
            ))
        records.append(record)

    print(f"faces detected: {detected}/{len(annotations)}")
    if missed:
        print("not measured:")
        for item in missed:
            print(f"  {item}")

    print("\n--- which landmark group is the viewer's left eye ---")
    best_convention, best_mean = None, -1.0
    for convention, parts in scores.items():
        combined = parts["eyeLeft"] + parts["eyeRight"]
        mean = float(np.mean(combined)) if combined else 0.0
        print(f"  {convention:12} eyeLeft {summarise(parts['eyeLeft'])}")
        print(f"  {'':12} eyeRight {summarise(parts['eyeRight'])}   combined mean {mean:.3f}")
        if mean > best_mean:
            best_convention, best_mean = convention, mean
    print(f"  -> {best_convention} (combined IoU {best_mean:.3f})")

    print("\n--- mouth ---")
    print(f"  IoU           {summarise(mouth_iou)}")
    print(f"  centre error  {summarise(mouth_centre)}  (fraction of the normalized diagonal)")

    print("\n--- head ---")
    print(f"  detected face box vs hand-drawn head box, IoU {summarise(head_iou_raw)}")
    if face_to_head:
        array = np.array(face_to_head)
        print("  the hand head box relative to the detected face box:")
        for index, label in enumerate(["centre dx", "centre dy", "width x", "height x"]):
            print(f"    {label:10} mean {array[:, index].mean():+.3f}  sd {array[:, index].std():.3f}")
        print("  a small sd means the head box can be derived from the face box by a fixed rule.")

    # --- after fitting the box convention ------------------------------------
    #
    # The raw IoU above compares a landmark hull against a hand-drawn box that
    # deliberately covers more: Arils eye rects are "the visible eye unit,
    # lashes and iris", and the head rect is a search region including hair.
    # Those differ from the detector's output by a fixed transform, not by
    # error, which the near-zero centre errors show. So fit that transform and
    # measure what is left. Leave-one-out, because fitting four numbers on
    # sixteen samples and scoring on the same sixteen would report nothing.
    #
    # The fit is a median, not a mean. On the three faces lying sideways the
    # hand labels and the landmark groups disagree about which eye is which
    # (see the side check below), giving eye offsets of 2-4 hull widths where
    # every other eye sits within 0.3. A mean let those three pull both eye
    # boxes half an eye width toward the nose on every image; the median
    # ignores them (leave-one-out eye IoU 0.35 -> 0.52 on the v1 labels).
    print("\n--- after fitting the box convention (median, leave-one-out) ---")
    fitted_constants: dict[str, list[float]] = {}
    for part, sources in fit_inputs.items():
        if len(sources) < 3:
            print(f"  {part:9} too few samples")
            continue
        ratios = np.array([
            [
                (t["x"] + t["width"] / 2 - (s["x"] + s["width"] / 2)) / max(s["width"], 1e-6),
                (t["y"] + t["height"] / 2 - (s["y"] + s["height"] / 2)) / max(s["height"], 1e-6),
                t["width"] / max(s["width"], 1e-6),
                t["height"] / max(s["height"], 1e-6),
            ]
            for s, t in sources
        ])
        fitted = []
        for index in range(len(sources)):
            others = np.median(np.delete(ratios, index, axis=0), axis=0)
            source, target = sources[index]
            cx = source["x"] + source["width"] / 2 + others[0] * source["width"]
            cy = source["y"] + source["height"] / 2 + others[1] * source["height"]
            w, h = source["width"] * others[2], source["height"] * others[3]
            fitted.append(iou({"x": cx - w / 2, "y": cy - h / 2, "width": w, "height": h}, target))
        split = ""
        if drafted:
            from_draft = [v for v, n in zip(fitted, fit_names[part]) if n in drafted]
            without = [v for v, n in zip(fitted, fit_names[part]) if n not in drafted]
            if from_draft and without:
                split = f"   [from draft {np.mean(from_draft):.3f} n={len(from_draft)} / without {np.mean(without):.3f} n={len(without)}]"
        print(f"  {part:9} IoU {summarise(fitted)}{split}   "
              f"(scale w {np.median(ratios[:, 2]):.2f} "
              f"h {np.median(ratios[:, 3]):.2f}, range {ratios[:, 3].min():.1f}-{ratios[:, 3].max():.1f})")
        fitted_scores[part] = float(np.mean(fitted))
        fitted_constants[part] = [round(float(v), 4) for v in np.median(ratios, axis=0)]

    if side_swapped:
        print("\n  eyes labelled opposite to the landmark groups (viewer vs character side):")
        for name in side_swapped:
            print(f"    {name}")

    # The numbers to paste into make_draft_annotations.CALIBRATION and
    # AnimeFaceServiceEstimator.BoxCalibration, fitted on every sample.
    print("\n--- calibration to ship (median over all samples: dx, dy, w, h) ---")
    for part, constants in fitted_constants.items():
        print(f"  {part:9} {tuple(constants)}")

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "detector_measurement.json").write_text(json.dumps({
            "detector": args.detector,
            "entries": len(annotations),
            "detected": detected,
            "convention": best_convention,
            "eyeCombinedIoU": best_mean,
            "mouthIoU": float(np.mean(mouth_iou)) if mouth_iou else None,
            "headIoUvsFaceBox": float(np.mean(head_iou_raw)) if head_iou_raw else None,
            "fittedIoU": fitted_scores,
            "calibration": fitted_constants,
            "faceToHead": np.array(face_to_head).mean(axis=0).tolist() if face_to_head else None,
            "records": records,
        }, indent=1, ensure_ascii=False))
        print(f"\nwrote {args.out / 'detector_measurement.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
