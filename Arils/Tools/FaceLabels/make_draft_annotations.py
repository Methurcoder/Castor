#!/usr/bin/env python3
"""Pre-label images with the anime face detector so a person only has to correct.

Drawing four rectangles from scratch is slow; dragging a mostly-right rectangle
into place is not. Measured against the sixteen hand-verified images, the
detector plus the fitted box calibration reaches a head IoU of 0.671 and places
the mouth within about a thousandth of the image diagonal, so most of a draft
survives review untouched and the time goes where the draft is wrong.

The output is deliberately easy to tell apart from ground truth. It is a
separate file, its `model` is the detector rather than `human`, and every
entry's `review.state` is `draftPendingHumanReview`. Nothing here may be fed
back into a calibration or an evaluation set until a person has actually looked
at it: a draft scored against the detector that produced it measures nothing.

    python3 make_draft_annotations.py                    # write the draft file
    python3 make_draft_annotations.py --dry-run          # just report coverage

Entries are ordered weakest-detection-first, so the images most likely to need
real work come up before the ones that need a glance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from measure_detector import EYE_A, EYE_B, MOUTH, OUTLINE, box_from  # noqa: E402

DEFAULT_DATASET = pathlib.Path.home() / "開発/Pomegranate/Arils_Dataset"
SCHEMA_VERSION = 3
DRAFT_STATE = "draftPendingHumanReview"

#: Fitted on the sixteen hand-verified images by `measure_detector.py` (median), as
#: (centre dx, centre dy, width scale, height scale) in units of the source box.
#: The Swift runtime keeps the same numbers in
#: `AnimeFaceServiceEstimator.BoxCalibration`; re-fit both together when the
#: verified set grows.
CALIBRATION = {
    "head":     (0.0443, -0.3656, 1.8395, 1.6966),
    "eyeLeft":  (-0.0720, -0.5340, 1.9879, 2.5747),
    "eyeRight": (-0.1256, -0.5479, 1.8251, 2.5383),
    "mouth":    (-0.0213, 0.0404, 1.7465, 2.6017),
}


def calibrated_centre_box(source: dict, part: str) -> dict:
    """Applies the fit and returns the centre-normalized box the schema wants.

    `measure_detector` works in top-left boxes because that is what IoU needs;
    the annotation files store `normalizedCenterXYWidthHeight`, so the centre is
    what goes out.
    """
    dx, dy, width_scale, height_scale = CALIBRATION[part]
    width = source["width"] * width_scale
    height = source["height"] * height_scale
    centre_x = source["x"] + source["width"] / 2 + dx * source["width"]
    centre_y = source["y"] + source["height"] / 2 + dy * source["height"]
    # Clip to the image, as the Swift estimator does: a head near the top edge
    # otherwise extends above it and the schema rightly rejects the box.
    left, right = max(0.0, centre_x - width / 2), min(1.0, centre_x + width / 2)
    top, bottom = max(0.0, centre_y - height / 2), min(1.0, centre_y + height / 2)
    return {
        "x": round(float((left + right) / 2), 6),
        "y": round(float((top + bottom) / 2), 6),
        "width": round(float(right - left), 6),
        "height": round(float(bottom - top), 6),
    }


#: Label rules v2 (face_labeler.py shows the same rules to the person).
#: Only the parts the detector can see are ruled here; the neck base is not a
#: landmark, so its draft is a proportion of the face and always needs a look.
NECK_LENGTH_PER_FACE_HEIGHT = 0.45
NECK_WIDTH_PER_FACE_WIDTH = 0.38
CLOSED_MOUTH_HEIGHT_PER_WIDTH = 0.25


def apply_label_rules(parts: dict, points: np.ndarray, face_box: dict) -> None:
    """Moves a calibrated draft onto the v2 label rules, in place.

    head   bottom edge at the chin, since that edge is the rig's neck cut
    mouth  never flatter than a quarter of its width, so a closed mouth is
           drawn the same way on every image
    neck   chin to the collar, the width of the neck; a guess to be corrected
    """
    chin = points[OUTLINE][np.argmax(points[OUTLINE][:, 1])]
    chin_x, chin_y = float(chin[0]), float(chin[1])

    head = parts["head"]["box"]
    top = head["y"] - head["height"] / 2
    if chin_y > top:
        head["y"] = round((top + chin_y) / 2, 6)
        head["height"] = round(chin_y - top, 6)

    mouth = parts["mouth"]["box"]
    mouth["height"] = round(max(mouth["height"], mouth["width"] * CLOSED_MOUTH_HEIGHT_PER_WIDTH), 6)

    neck_height = min(face_box["height"] * NECK_LENGTH_PER_FACE_HEIGHT, 1.0 - chin_y)
    neck_width = face_box["width"] * NECK_WIDTH_PER_FACE_WIDTH
    if neck_height > 0 and neck_width > 0:
        parts["neck"] = {
            "visibility": "visible",
            # Low on purpose: the base of the neck is proportion, not detection.
            "confidence": 0.3,
            "box": {
                "x": round(min(max(chin_x, neck_width / 2), 1 - neck_width / 2), 6),
                "y": round(chin_y + neck_height / 2, 6),
                "width": round(neck_width, 6),
                "height": round(neck_height, 6),
            },
        }


def load_targets(dataset: pathlib.Path) -> tuple[list[dict], set[str], set[str]]:
    """Returns the manifest items, the images already hand-verified, and the
    images deliberately set aside."""
    manifest = json.loads((dataset / "manifest.json").read_text())
    manual_path = dataset / "arils_manual_annotations.json"
    verified: set[str] = set()
    skipped: set[str] = set()
    if manual_path.exists():
        manual = json.loads(manual_path.read_text())
        verified = {e["image"] for e in manual.get("entries", [])}
        skipped = {s["image"] for s in manual.get("skipped", [])}
    return manifest["items"], verified, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=pathlib.Path, default=DEFAULT_DATASET)
    parser.add_argument("--out", type=pathlib.Path, default=None,
                        help="default: <dataset>/arils_draft_annotations.json")
    parser.add_argument("--detector", default="faster-rcnn", choices=["faster-rcnn", "yolov3"])
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--include-verified", action="store_true",
                        help="also draft images that already have hand labels (for comparison only)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    dataset: pathlib.Path = args.dataset
    out = args.out or (dataset / "arils_draft_annotations.json")
    items, verified, deliberately_skipped = load_targets(dataset)

    todo = []
    for item in items:
        name = pathlib.Path(item["file"]).name
        path = dataset / item["file"]
        if not path.exists():
            print(f"[draft] missing file, skipping: {item['file']}")
            continue
        if name in deliberately_skipped:
            print(f"[draft] set aside upstream, skipping: {name}")
            continue
        if name in verified and not args.include_verified:
            continue
        todo.append((item, path, name))

    print(f"[draft] {len(items)} in manifest, {len(verified)} already hand-verified, "
          f"{len(todo)} to draft")
    if args.dry_run:
        for item, _, name in todo:
            print(f"  {item['id']:6} {item['category']:28} {name}")
        return 0
    if not todo:
        print("[draft] nothing to do")
        return 0

    from anime_face_detector import create_detector
    from PIL import Image

    detector = create_detector(face_detector_name=args.detector, device=args.device)

    entries: list[dict] = []
    failures: list[str] = []
    for item, path, name in todo:
        with Image.open(path) as image:
            width, height = image.size
            array = np.asarray(image.convert("RGB"))[:, :, ::-1]
        predictions = detector(np.ascontiguousarray(array))
        if not predictions:
            failures.append(name)
            print(f"[draft] no face found: {name}")
            continue

        best = max(predictions, key=lambda p: float(np.asarray(p["bbox"])[4]))
        bbox = np.asarray(best["bbox"], dtype=np.float32)
        points = np.asarray(best["keypoints"], dtype=np.float32).copy()
        points[:, 0] /= width
        points[:, 1] /= height
        face_box = {
            "x": float(bbox[0] / width), "y": float(bbox[1] / height),
            "width": float((bbox[2] - bbox[0]) / width),
            "height": float((bbox[3] - bbox[1]) / height),
        }
        detection_score = float(bbox[4])
        landmark_scores = points[:, 2]
        landmark_mean = float(landmark_scores.mean())
        landmark_min = float(landmark_scores.min())

        sources = {
            "head": face_box,
            "eyeLeft": box_from(points, EYE_A),
            "eyeRight": box_from(points, EYE_B),
            "mouth": box_from(points, MOUTH),
        }
        parts = {
            part: {
                "visibility": "visible",
                "confidence": round(landmark_mean, 4),
                "box": calibrated_centre_box(source, part),
            }
            for part, source in sources.items()
        }
        apply_label_rules(parts, points, face_box)

        note = ("Drafted by the anime face detector with the calibration fitted on the "
                "sixteen hand-verified images. Every box must be checked and corrected "
                "before this entry counts as ground truth.")
        if landmark_min < 0.5:
            note += f" Weakest landmark score {landmark_min:.2f}; expect to move something."
        entries.append({
            "image": name,
            "annotation": {
                "faceSetConfidence": round(detection_score, 4),
                "mediaKind": "2d",
                "contentRating": "safe",
                "contentConfidence": 1.0,
                "faces": [{
                    "faceConfidence": round(detection_score, 4),
                    "faceView": "unknown",
                    "viewConfidence": 0.0,
                    "parts": parts,
                    "normalizationWarnings": ["faceViewNotEstimatedByDetector"],
                    "faceId": "face-001",
                }],
            },
            "review": {"state": DRAFT_STATE, "issues": [], "note": note},
            "group": item["id"],
            "category": item["category"],
            "generator": "anime-face-detector-draft",
            "draftMetrics": {
                "detectionScore": round(detection_score, 4),
                "landmarkScoreMean": round(landmark_mean, 4),
                "landmarkScoreMin": round(landmark_min, 4),
                "facesDetected": len(predictions),
            },
        })

    # Weakest first: the images where the draft is least trustworthy are the
    # ones worth a person's attention, so they should not be buried at the end.
    entries.sort(key=lambda e: e["draftMetrics"]["landmarkScoreMin"])

    now = dt.datetime.now(dt.timezone.utc).isoformat()
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "labelConvention": "viewerLeftRight",
        "faceConvention": "allLocalizedFacesTopToBottomThenLeftToRight",
        "coordinateConvention": "normalizedCenterXYWidthHeight",
        "promptVersion": "anime-face-detector-draft-v2",
        "labelRules": "v2",
        "model": f"hysts/anime-face-detector ({args.detector}) + fitted calibration",
        "status": "draft",
        "warning": ("NOT ground truth. Every entry is machine-drafted and must be reviewed and "
                    "corrected by a person before use. Do not calibrate or evaluate the detector "
                    "against these labels; that would score the detector against itself."),
        "createdAt": now,
        "updatedAt": now,
        "input": {"kind": "imageDirectory", "imageRoot": str(dataset / "images")},
        "source": {
            "manifest": str(dataset / "manifest.json"),
            "calibration": "Arils/Tools/FaceLabels/measure_detector.py",
        },
        "skipped": [{"image": n, "reason": "no face detected by the drafter"} for n in failures],
        "entries": entries,
        "errors": [],
    }
    out.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n")

    print(f"\n[draft] wrote {out}")
    print(f"[draft] {len(entries)} drafted, {len(failures)} without a detection")
    if entries:
        print("\nreview these first (weakest landmark score):")
        for entry in entries[:6]:
            metrics = entry["draftMetrics"]
            print(f"  {entry['group']:6} {entry['image'][:34]:36} "
                  f"min {metrics['landmarkScoreMin']:.2f}  faces {metrics['facesDetected']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
