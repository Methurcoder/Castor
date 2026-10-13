#!/bin/zsh
# Starts the optional localhost anime face-landmark service used by Arils.
#
# Nothing in Castor requires this. When it is not running, Arils uses its
# own AnimeFaceEstimator, exactly as before. Stop it with Ctrl-C.
#
#   scripts/bootstrap-anime-face.sh      # once
#   scripts/start-anime-face.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
server="$repo_root/scripts/anime_face_server.py"
python="$repo_root/.castor-anime-face/bin/python"
# Existing installations can keep their local helper environment.
if [[ ! -x "$python" && -x "$repo_root/.pomegranate-anime-face/bin/python" ]]; then
    python="$repo_root/.pomegranate-anime-face/bin/python"
fi

if [[ ! -x "$python" ]]; then
    # A Python that already has the package (a developer machine) is fine too.
    if python3 -c "import anime_face_detector" >/dev/null 2>&1; then
        python="$(command -v python3)"
    else
        echo "Run scripts/bootstrap-anime-face.sh first." >&2
        exit 1
    fi
fi

export ARILS_FACE_HOST="127.0.0.1"
export ARILS_FACE_PORT="${ARILS_FACE_PORT:-8131}"
export ARILS_FACE_DETECTOR="${ARILS_FACE_DETECTOR:-faster-rcnn}"
export ARILS_FACE_DEVICE="${ARILS_FACE_DEVICE:-cpu}"
export ARILS_FACE_PRELOAD="${ARILS_FACE_PRELOAD:-1}"

echo "Starting Arils anime face landmarks at http://$ARILS_FACE_HOST:$ARILS_FACE_PORT"
exec "$python" "$server"
