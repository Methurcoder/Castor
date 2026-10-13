#!/bin/zsh
set -euo pipefail

# Installs the optional anime face-landmark helper into its own environment,
# the same arrangement as scripts/bootstrap-lama-inpainting.sh.
#   hysts/anime-face-detector: MIT (vendored mmdet/mmpose parts: Apache-2.0)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
venv="$repo_root/.castor-anime-face"

if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install --upgrade "anime-face-detector==0.1.0" pillow numpy

echo "Anime face-landmark environment is ready."
echo "Start it with: $repo_root/scripts/start-anime-face.sh"
echo "The detector weights may be downloaded on the first start."
