#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python="$repo_root/.castor-lama/bin/python"
# Existing installations can keep their local helper environment.
if [[ ! -x "$python" && -x "$repo_root/.pomegranate-lama/bin/python" ]]; then
    python="$repo_root/.pomegranate-lama/bin/python"
fi
server="$repo_root/scripts/lama_inpainting_server.py"

if [[ ! -x "$python" ]]; then
    echo "Run scripts/bootstrap-lama-inpainting.sh first." >&2
    exit 1
fi

export POME_LAMA_HOST="127.0.0.1"
export POME_LAMA_PORT="${POME_LAMA_PORT:-8123}"
export POME_LAMA_PRELOAD="${POME_LAMA_PRELOAD:-1}"

echo "Starting Castor LaMa inpainting at http://$POME_LAMA_HOST:$POME_LAMA_PORT"
exec "$python" "$server"
