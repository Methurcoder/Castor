#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
venv="$repo_root/.castor-tts"

if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install --upgrade mlx-audio

echo "Neural TTS environment is ready."
echo "Start it with: $repo_root/scripts/start-neural-tts.sh"
