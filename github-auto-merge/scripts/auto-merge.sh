#!/usr/bin/env bash
# github-auto-merge script: auto-merge
#
# task_done イベントで発火する。
# 完了タスクの PR を自動マージする。
#
# gate として実行される。タスク JSON は stdin から受け取る。

set -euo pipefail

echo "[auto-merge] starting"

# --- gate は stdin 経由でタスク JSON を受け取る ---
TASK_JSON=$(cat)

# --- helper: boid task update でペイロードを更新 ---
update_task_payload() {
    local task_id="$1"
    local payload_json="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/boid-auto-merge-payload.XXXXXX)
    printf '%s' "${payload_json}" > "${tmpfile}"
    boid task update "${task_id}" --payload-file "${tmpfile}" 2>&1 || echo "[auto-merge] WARNING: boid task update failed" >&2
    rm -f "${tmpfile}"
}

# --- 1. トリガー情報の取得 ---
TASK_ID=$(printf '%s' "${TASK_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
payload = data.get('payload', {}) or {}
print(payload.get('_trigger', {}).get('task_id', '') or '')
" 2>/dev/null || true)

if [ -z "${TASK_ID}" ]; then
    echo "[auto-merge] ERROR: could not determine TASK_ID from payload"
    exit 0
fi

BRANCH="boid/${TASK_ID:0:8}"
echo "[auto-merge] task=${TASK_ID} branch=${BRANCH}"

# --- 2. PR の存在確認 ---
PR_INFO=$(gh pr list --head "${BRANCH}" --state all \
    --json number,url,state \
    --jq '[.[] | select(.state == "OPEN" or .state == "MERGED")] | sort_by(.state == "OPEN" | not) | .[0]' \
    2>/dev/null || echo "")

if [ -z "${PR_INFO}" ] || [ "${PR_INFO}" = "null" ]; then
    echo "[auto-merge] no PR found for branch ${BRANCH}"
    update_task_payload "${TASK_ID}" "$(python3 -c "
import json
print(json.dumps({
    'artifact': {
        'pr': {'number': None, 'url': None, 'branch': '${BRANCH}', 'merged': False, 'error': None},
    },
}))
")"
    exit 0
fi

PR_NUMBER=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
PR_URL=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
PR_STATE=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

echo "[auto-merge] PR #${PR_NUMBER} (${PR_URL}) state=${PR_STATE}"

MERGE_STATUS=""
MERGE_ERROR=""

# --- 3. PR マージ ---
if [ "${PR_STATE}" = "MERGED" ]; then
    echo "[auto-merge] PR already merged"
    MERGE_STATUS="already_merged"
else
    MERGE_STDERR_FILE=$(mktemp /tmp/boid-auto-merge-err.XXXXXX)
    MERGE_EXIT=0

    gh pr merge "${PR_NUMBER}" --merge --delete-branch 2>"${MERGE_STDERR_FILE}" || MERGE_EXIT=$?
    MERGE_STDERR=$(cat "${MERGE_STDERR_FILE}")
    rm -f "${MERGE_STDERR_FILE}"

    if [ "${MERGE_EXIT}" -eq 0 ]; then
        echo "[auto-merge] PR merged successfully"
        MERGE_STATUS="merged"
    else
        echo "[auto-merge] ERROR: merge failed (exit=${MERGE_EXIT}): ${MERGE_STDERR}"
        MERGE_STATUS="merge_failed"
        MERGE_ERROR="${MERGE_STDERR}"
    fi
fi

# --- 4. artifact 出力 ---
export PR_NUMBER PR_URL BRANCH MERGE_STATUS MERGE_ERROR
update_task_payload "${TASK_ID}" "$(python3 - <<'PYEOF'
import os, json

pr_number = int(os.environ.get('PR_NUMBER', '0'))
merge_error_str = os.environ.get('MERGE_ERROR', '')
merge_error = merge_error_str if merge_error_str else None
merge_status = os.environ.get('MERGE_STATUS', '')

print(json.dumps({
    'artifact': {
        'pr': {
            'number': pr_number,
            'url': os.environ.get('PR_URL', ''),
            'branch': os.environ.get('BRANCH', ''),
            'merged': merge_status in ('merged', 'already_merged'),
            'error': merge_error,
        },
    },
}))
PYEOF
)"

echo "[auto-merge] done"
