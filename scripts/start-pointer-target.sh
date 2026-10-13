#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python="$repo_root/.castor-pointer/bin/python"
# Existing installations can keep their local helper environment.
if [[ ! -x "$python" && -x "$repo_root/.pomegranate-pointer/bin/python" ]]; then
    python="$repo_root/.pomegranate-pointer/bin/python"
fi
server="$repo_root/scripts/pointer_target_server.py"

if [[ ! -x "$python" ]]; then
    echo "Run scripts/bootstrap-pointer-target.sh first." >&2
    exit 1
fi

export POME_POINTER_HOST="127.0.0.1"
export POME_POINTER_PORT="${POME_POINTER_PORT:-8126}"

exec "$python" "$server"
