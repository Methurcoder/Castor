# Visibility-layer baseline

Measured on 2026-08-09 with
`../Arils_Dataset/images/012(3)_pastfailure_right.png` (1024x1536,
opaque PNG).

## Automatic pass

- Vision body joints: 0
- Bust-up joints left unresolved: 7
- Legacy texture seeds: 7
- Layered texture seeds: 0
- Legacy arm parts that would have been attempted: 4
- Layered arm parts: 0
- Admission: rejected

This is a safer failure, not a successful automatic rig. The illustration is
outside Vision's reliable body-pose domain, so the topology layer refuses to
turn silhouette-template coordinates into source pixels.

## Visibility-reviewed pass

Command-line hints: left arm `occluded`, right arm `visible`.

- Occluded joints: 3
- Visible bust-up joints: 4 (neck plus right shoulder/elbow/wrist)
- Legacy arm parts: 4
- Layered arm parts: 2 (`rightUpperArm`, `rightForearm`)
- Admission: rejected until the four low-confidence template positions are
  placed on the drawing

The measurable gain is two prevented false arm-part extractions. Visibility
review does not raise coordinate confidence; the editor must still correct
the neck and visible arm when Vision supplies no points.
