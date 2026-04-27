#!/usr/bin/env bash
# auto-merge gate (entry gate on done)
#
# done 入場時に PR をマージし、結果を artifact に反映する。
# mergeable-check gate (verifying exit gate) で conflict が解消済みであることが前提。
#
# stdin: TaskJSON
# stdout: payload_patch (JSON)

set -euo pipefail

TASK_JSON=$(cat)

# --- タスク情報の取得 ---
TASK_ID=$(printf '%s' "${TASK_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('id', ''))
" 2>/dev/null || true)

BRANCH="boid/${TASK_ID:0:8}"
echo "[auto-merge] task=${TASK_ID} branch=${BRANCH}" >&2

# --- PR の存在確認 ---
PR_INFO=$(gh pr list --head "${BRANCH}" --state all \
    --json number,url,state \
    --jq '[.[] | select(.state == "OPEN" or .state == "MERGED")] | sort_by(.state == "OPEN" | not) | .[0]' \
    2>/dev/null || echo "")

if [ -z "${PR_INFO}" ] || [ "${PR_INFO}" = "null" ]; then
    echo "[auto-merge] no PR found for branch ${BRANCH}" >&2
    exit 0
fi

PR_NUMBER=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
PR_URL=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
PR_STATE=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

echo "[auto-merge] PR #${PR_NUMBER} (${PR_URL}) state=${PR_STATE}" >&2

# --- 既にマージ済み ---
if [ "${PR_STATE}" = "MERGED" ]; then
    echo "[auto-merge] PR already merged" >&2
    export PR_NUMBER PR_URL BRANCH
    python3 -c "
import os, json

patch = {
    'payload_patch': {
        'artifact': {
            'auto-merge': {
                'merged': True,
                'pr': {
                    'number': int(os.environ['PR_NUMBER']),
                    'url': os.environ['PR_URL'],
                    'branch': os.environ['BRANCH'],
                },
            },
        },
    },
}
print(json.dumps(patch, ensure_ascii=False))
"
    exit 0
fi

# --- マージ実行 ---
MERGE_STDERR_FILE=$(mktemp /tmp/boid-auto-merge-err.XXXXXX)
MERGE_EXIT=0

gh pr merge "${PR_NUMBER}" --merge 2>"${MERGE_STDERR_FILE}" || MERGE_EXIT=$?
MERGE_STDERR=$(cat "${MERGE_STDERR_FILE}")
rm -f "${MERGE_STDERR_FILE}"

if [ "${MERGE_EXIT}" -eq 0 ]; then
    echo "[auto-merge] PR merged successfully" >&2
    export PR_NUMBER PR_URL BRANCH
    python3 -c "
import os, json

patch = {
    'payload_patch': {
        'artifact': {
            'auto-merge': {
                'merged': True,
                'pr': {
                    'number': int(os.environ['PR_NUMBER']),
                    'url': os.environ['PR_URL'],
                    'branch': os.environ['BRANCH'],
                },
            },
        },
    },
}
print(json.dumps(patch, ensure_ascii=False))
"
else
    echo "[auto-merge] ERROR: merge failed (exit=${MERGE_EXIT}): ${MERGE_STDERR}" >&2
    export PR_NUMBER PR_URL BRANCH MERGE_STDERR
    python3 -c "
import os, json

patch = {
    'payload_patch': {
        'artifact': {
            'auto-merge': {
                'merged': False,
                'error': 'late_conflict',
                'pr': {
                    'number': int(os.environ['PR_NUMBER']),
                    'url': os.environ['PR_URL'],
                    'branch': os.environ['BRANCH'],
                },
            },
        },
    },
}
print(json.dumps(patch, ensure_ascii=False))
"
fi
