#!/usr/bin/env python3
"""Which hand labels still sit exactly where their starting point put them.

`face_labeler.py` marks every saved entry `humanAccepted` with the current
label rules, whether or not a box was moved. That is right for the head and
neck, which the labeller's buttons snap into place, but an eye or mouth box
left untouched is still the detector's draft (or a box drawn to the older v1
rules), and measuring the detector against its own draft scores 1.000 and
means nothing. This lists, per image and part, whether the box has moved away
from where it started.

    python3 review_status.py            # table plus a one-line summary
    python3 review_status.py --todo     # only the images that still need work

Starting points: the detector draft for images that had one, else the oldest
backup of the manual file (the v1 hand labels from before face_labeler.py).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

DEFAULT_DATASET = pathlib.Path.home() / "開発/Pomegranate/Arils_Dataset"
CHECKED = ("eyeLeft", "eyeRight", "mouth")
#: Below this, in normalized image units, a box counts as not moved. A real
#: correction of a thin eye or mouth box moves at least an edge by a pixel or
#: two, which is ~0.001 on these images; float rounding is ~1e-6.
MOVED = 1e-4


def entries(path: pathlib.Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    return {e["image"]: e for e in json.loads(path.read_text()).get("entries", [])}


def parts(entry: dict) -> dict:
    faces = entry["annotation"].get("faces") or []
    return (faces[0].get("parts") or {}) if faces else {}


def moved(a: dict | None, b: dict | None) -> bool | None:
    if not a or not b or not a.get("box") or not b.get("box"):
        return None
    return max(abs(a["box"][k] - b["box"][k]) for k in ("x", "y", "width", "height")) > MOVED


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=pathlib.Path, default=DEFAULT_DATASET)
    parser.add_argument("--todo", action="store_true", help="list only images with an unmoved part")
    args = parser.parse_args()

    manual = entries(args.dataset / "arils_manual_annotations.json")
    draft = entries(args.dataset / "arils_draft_annotations.json")
    backups = sorted((args.dataset / "backups").glob("arils_manual_annotations.*.json"))
    original = entries(backups[0]) if backups else {}

    done, todo = 0, 0
    print(f"{'image':38} {'start':6} " + " ".join(f"{p:9}" for p in CHECKED))
    for name in sorted(manual):
        if name in draft:
            start, base = "draft", parts(draft[name])
        elif name in original:
            start, base = "v1", parts(original[name])
        else:
            start, base = "none", {}
        current = parts(manual[name])
        states = {p: moved(current.get(p), base.get(p)) for p in CHECKED}
        pending = [p for p, s in states.items() if s is False]
        if pending:
            todo += 1
        else:
            done += 1
        if args.todo and not pending:
            continue
        cells = " ".join(f"{'moved' if s else ('NOT YET' if s is False else '-'):9}" for s in states.values())
        print(f"{name[:37]:38} {start:6} {cells}")

    print(f"\n{done} done, {todo} still have an eye or mouth box exactly where it started")
    print("(a box that already follows the v2 rules still shows here until it moves: select it and"
          " press one arrow key, a 1px nudge, to record that you looked)")
    return 0 if todo == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
