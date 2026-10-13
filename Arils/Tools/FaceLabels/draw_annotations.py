#!/usr/bin/env python3
"""Draw an annotation file's boxes onto its images, for review by eye.

Works on any file using the project's annotation schema, so the same view
serves a machine draft and a hand-verified set. Boxes are stored as
`normalizedCenterXYWidthHeight`, which is easy to misread as a corner; drawing
them is the cheapest way to be sure the file says what it is meant to say.

    python3 draw_annotations.py arils_draft_annotations.json --out review/
    python3 draw_annotations.py arils_manual_annotations.json --out review-manual/

A contact sheet is written alongside the individual overlays so a whole set can
be scanned at once.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from PIL import Image, ImageDraw

COLOURS = {
    "head": (80, 200, 255),
    "eyeLeft": (60, 255, 90),
    "eyeRight": (90, 140, 255),
    "mouth": (255, 70, 70),
}


def centre_box_to_pixels(box: dict, width: int, height: int) -> tuple[float, float, float, float]:
    """`normalizedCenterXYWidthHeight` to pixel corners."""
    w = box["width"] * width
    h = box["height"] * height
    cx = box["x"] * width
    cy = box["y"] * height
    return cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2


def draw_entry(entry: dict, image_root: pathlib.Path, out_dir: pathlib.Path) -> pathlib.Path | None:
    path = image_root / entry["image"]
    if not path.exists():
        return None
    with Image.open(path) as source:
        image = source.convert("RGB")
    draw = ImageDraw.Draw(image)
    width, height = image.size
    line = max(2, round(min(width, height) / 400))

    for face in entry["annotation"].get("faces", []):
        for name, part in (face.get("parts") or {}).items():
            box = part.get("box")
            if not box or not box.get("width"):
                continue
            x0, y0, x1, y1 = centre_box_to_pixels(box, width, height)
            colour = COLOURS.get(name, (255, 255, 255))
            draw.rectangle([x0, y0, x1, y1], outline=colour, width=line)
            draw.text((x0 + line + 2, y0 + line + 2), name, fill=colour)

    state = entry.get("review", {}).get("state", "")
    draw.text((8, 8), f"{entry.get('group', '')} {entry['image']}  [{state}]", fill=(255, 255, 0))
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / (pathlib.Path(entry["image"]).stem + "_review.png")
    image.save(target)
    return target


def contact_sheet(paths: list[pathlib.Path], target: pathlib.Path, columns: int = 4, cell: int = 420) -> None:
    if not paths:
        return
    rows = (len(paths) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * cell, rows * cell), (18, 18, 22))
    for index, path in enumerate(paths):
        with Image.open(path) as image:
            thumb = image.convert("RGB")
            thumb.thumbnail((cell, cell))
            x = (index % columns) * cell + (cell - thumb.width) // 2
            y = (index // columns) * cell + (cell - thumb.height) // 2
            sheet.paste(thumb, (x, y))
    sheet.save(target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("annotations", type=pathlib.Path)
    parser.add_argument("--dataset", type=pathlib.Path,
                        default=pathlib.Path.home() / "開発/Pomegranate/Arils_Dataset")
    parser.add_argument("--out", type=pathlib.Path, default=None)
    args = parser.parse_args()

    path = args.annotations
    if not path.is_absolute():
        path = args.dataset / path
    document = json.loads(path.read_text())
    if document.get("coordinateConvention") != "normalizedCenterXYWidthHeight":
        print(f"unexpected coordinateConvention: {document.get('coordinateConvention')}", file=sys.stderr)
        return 1

    image_root = pathlib.Path(document.get("input", {}).get("imageRoot") or (args.dataset / "images"))
    out_dir = args.out or (args.dataset / "review" / path.stem)
    written: list[pathlib.Path] = []
    for entry in document.get("entries", []):
        target = draw_entry(entry, image_root, out_dir)
        if target:
            written.append(target)
        else:
            print(f"missing image for {entry['image']}", file=sys.stderr)

    sheet = out_dir / "_contact_sheet.png"
    contact_sheet(written, sheet)
    print(f"wrote {len(written)} overlays to {out_dir}")
    print(f"contact sheet: {sheet}")
    print(f"status: {document.get('status', 'unstated')}  model: {document.get('model')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
