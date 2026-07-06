#!/bin/bash
# One-time setup on a Mac: create the virtual environment and install deps.
# Requires Python 3 (e.g. `brew install python`).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
    echo "❌ Python 3 is required. Install it (e.g. 'brew install python') and re-run." >&2
    exit 1
fi

echo "→ Creating virtual environment (.venv)…"
"$PY" -m venv .venv
echo "→ Installing dependencies…"
.venv/bin/python -m pip install --upgrade pip -q
.venv/bin/python -m pip install -r requirements.txt

echo
echo "✅ Installed. Next steps:"
echo "   • Run now:         .venv/bin/python distractor_remover.py"
echo "   • Start at login:  ./enable_autostart.sh"
