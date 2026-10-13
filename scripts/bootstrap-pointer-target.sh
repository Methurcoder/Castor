#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
venv="$repo_root/.castor-pointer"

if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
fi

"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install --upgrade "pyobjc-framework-ApplicationServices"

echo "Pointer-target helper environment is ready."
echo "Start it with: $repo_root/scripts/start-pointer-target.sh"
echo "The first start asks for Accessibility access (System Settings › Privacy & Security › Accessibility)."
