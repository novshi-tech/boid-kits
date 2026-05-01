#!/usr/bin/env bash
# auto-merge gate (phase: exit)
#
# task の executing 退場時に発火する host gate。
# PR の mergeable ステータスをポーリングし、MERGEABLE なら `gh pr merge` で
# 実マージする。CONFLICTING なら exit 非ゼロで終了し、state machine 側で
# job_failed → aborted に遷移させる。
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

emit_artifact() {
    # emit_artifact <merged: true|false> [error]
    export AM_MERGED="$1" AM_ERROR="${2:-}" AM_PR_NUMBER="${PR_NUMBER:-}" AM_PR_URL="${PR_URL:-}" AM_BRANCH="${BRANCH}"
    python3 - <<'PYEOF'
import os, json

am = {
    'merged': os.environ['AM_MERGED'] == 'true',
    'pr': {
        'branch': os.environ['AM_BRANCH'],
    },
}
if os.environ.get('AM_PR_NUMBER'):
    am['pr']['number'] = int(os.environ['AM_PR_NUMBER'])
if os.environ.get('AM_PR_URL'):
    am['pr']['url'] = os.environ['AM_PR_URL']
if os.environ.get('AM_ERROR'):
    am['error'] = os.environ['AM_ERROR']

patch = {'payload_patch': {'artifact': {'auto-merge': am}}}
print(json.dumps(patch, ensure_ascii=False))
PYEOF
}

# --- PR の存在確認 ---
PR_INFO=$(gh pr list --head "${BRANCH}" --state all \
    --json number,url,state \
    --jq '[.[] | select(.state == "OPEN" or .state == "MERGED")] | sort_by(.state == "OPEN" | not) | .[0]' \
    2>/dev/null || echo "")

if [ -z "${PR_INFO}" ] || [ "${PR_INFO}" = "null" ]; then
    echo "[auto-merge] no PR found for branch ${BRANCH}" >&2
    PR_NUMBER="" PR_URL=""
    emit_artifact false no_pr
    exit 1
fi

PR_NUMBER=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
PR_URL=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
PR_STATE=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

echo "[auto-merge] PR #${PR_NUMBER} (${PR_URL}) state=${PR_STATE}" >&2

# --- 既にマージ済み ---
if [ "${PR_STATE}" = "MERGED" ]; then
    echo "[auto-merge] PR already merged" >&2
    emit_artifact true
    exit 0
fi

# --- mergeable ステータスのポーリング ---
MAX_RETRIES="${BOID_MERGE_POLL_RETRIES:-6}"
INTERVAL="${BOID_MERGE_POLL_INTERVAL:-10}"
MERGEABLE="UNKNOWN"

for i in $(seq 1 "${MAX_RETRIES}"); do
    MERGEABLE=$(gh pr view "${PR_NUMBER}" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
    if [ "${MERGEABLE}" != "UNKNOWN" ]; then
        echo "[auto-merge] PR #${PR_NUMBER} mergeable=${MERGEABLE} (attempt ${i}/${MAX_RETRIES})" >&2
        break
    fi
    echo "[auto-merge] PR #${PR_NUMBER} mergeable=UNKNOWN, retrying (attempt ${i}/${MAX_RETRIES})" >&2
    if [ "${i}" -lt "${MAX_RETRIES}" ]; then
        sleep "${INTERVAL}"
    fi
done

# --- conflict: abort ---
if [ "${MERGEABLE}" = "CONFLICTING" ]; then
    echo "[auto-merge] PR #${PR_NUMBER} has merge conflicts; aborting" >&2
    emit_artifact false merge_conflict
    exit 1
fi

# --- マージ実行 (MERGEABLE / UNKNOWN いずれも試行) ---
MERGE_STDERR_FILE=$(mktemp /tmp/boid-auto-merge-err.XXXXXX)
MERGE_EXIT=0

gh pr merge "${PR_NUMBER}" --merge 2>"${MERGE_STDERR_FILE}" || MERGE_EXIT=$?
MERGE_STDERR=$(cat "${MERGE_STDERR_FILE}")
rm -f "${MERGE_STDERR_FILE}"

if [ "${MERGE_EXIT}" -eq 0 ]; then
    echo "[auto-merge] PR merged successfully" >&2
    emit_artifact true
    exit 0
fi

echo "[auto-merge] ERROR: merge failed (exit=${MERGE_EXIT}): ${MERGE_STDERR}" >&2
emit_artifact false late_conflict
exit 1
