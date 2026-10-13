#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python="$repo_root/.castor-tts/bin/python"
# Existing installations can keep their local helper environment.
if [[ ! -x "$python" && -x "$repo_root/.pomegranate-tts/bin/python" ]]; then
    python="$repo_root/.pomegranate-tts/bin/python"
fi
server="$repo_root/scripts/neural_tts_server.py"

if [[ ! -x "$python" ]]; then
    echo "Run scripts/bootstrap-neural-tts.sh first." >&2
    exit 1
fi

export POME_TTS_MODEL="${POME_TTS_MODEL:-mlx-community/Irodori-TTS-600M-v3-VoiceDesign-8bit}"
export POME_IRODORI_NUM_STEPS="${POME_IRODORI_NUM_STEPS:-6}"
export POME_TTS_PRELOAD="${POME_TTS_PRELOAD:-1}"

echo "Starting Castor TTS with $POME_TTS_MODEL"
exec "$python" "$server"
