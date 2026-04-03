#!/bin/bash
set -euo pipefail

# ~/.codex/skills/boid-sandbox が存在しない場合はシンボリックリンクを作成する
SKILLS_SRC="${HOME}/.local/share/boid/skills/boid-sandbox"
SKILLS_LINK="${HOME}/.codex/skills/boid-sandbox"
if [ ! -e "$SKILLS_LINK" ] && [ ! -L "$SKILLS_LINK" ]; then
    mkdir -p "$(dirname "$SKILLS_LINK")"
    ln -s "$SKILLS_SRC" "$SKILLS_LINK"
fi

PROMPT="$(
python3 -c '
import json
import sys
import os

instructions_json = os.environ.get("BOID_INSTRUCTIONS", "")
if not instructions_json:
    sys.exit(0)

try:
    instructions = json.loads(instructions_json)
except json.JSONDecodeError as exc:
    print(f"ERROR: invalid BOID_INSTRUCTIONS JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

messages = [inst.get("message", "") for inst in instructions if inst.get("message")]
sys.stdout.write("\n\n".join(messages))
'
)"

if [ -z "$PROMPT" ]; then
    echo "ERROR: task payload must include a non-empty instructions trait" >&2
    exit 1
fi

# Keep boid hook stdout machine-readable; send Codex output to stderr.
printf '%s' "$PROMPT" | codex exec --sandbox danger-full-access --skip-git-repo-check - 1>&2
printf '%s\n' '{"payload_patch":{}}'
