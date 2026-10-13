#!/bin/zsh
# Double-click in Finder. Opens the face-box labeller for Arils_Dataset in the
# browser (http://127.0.0.1:8140). Keep this window open while labelling;
# close it or press Ctrl-C to stop. Saves go to arils_manual_annotations.json,
# with a backup taken before the first save of each session.
cd "$(dirname "$0")"

if curl -fsS --max-time 2 http://127.0.0.1:8140/api/items >/dev/null 2>&1; then
    open "http://127.0.0.1:8140"
    echo "The labeller is already running; opened it in the browser. You can close this window."
    exit 0
fi

exec python3 Arils/Tools/FaceLabels/face_labeler.py
