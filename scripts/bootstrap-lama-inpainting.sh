#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
venv="$repo_root/.castor-lama"

if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install --upgrade "simple-lama-inpainting==0.1.2"

echo "LaMa inpainting environment is ready."
echo "Start it with: $repo_root/scripts/start-lama-inpainting.sh"
echo "The LaMa weights may be downloaded on the first start."
