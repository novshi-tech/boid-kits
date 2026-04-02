#!/bin/bash
set -euo pipefail

PROMPT="$(
python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"ERROR: invalid hook payload JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

prompt = payload.get("prompt")
if prompt is None:
    raise SystemExit(0)
if not isinstance(prompt, str):
    print("ERROR: hook payload field \"prompt\" must be a string", file=sys.stderr)
    raise SystemExit(1)

sys.stdout.write(prompt)
'
)"

if [ -z "$PROMPT" ]; then
    echo "ERROR: task payload must include a non-empty prompt trait" >&2
    exit 1
fi

# Keep boid hook stdout machine-readable; send Codex output to stderr.
printf '%s' "$PROMPT" | codex exec --sandbox danger-full-access --skip-git-repo-check - 1>&2
printf '%s\n' '{"payload_patch":{}}'
