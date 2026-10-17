#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$DIR")"
PY="$WORKSPACE/.venv/bin/python"
if [ ! -x "$PY" ]; then
    echo "Create the shared environment first: $WORKSPACE/setup-python.sh" >&2
    exit 1
fi
"$PY" -m pip install -r "$DIR/requirements.txt"
echo "Installed. Run: $PY $DIR/distractor_remover.py"
