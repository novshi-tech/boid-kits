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

# PR を探すブランチ名は worktree の現在 HEAD を優先する。
# task description で agent に独自ブランチ名 (例: feature/...) への切替を
# 指示するケースがあり、 task ID 由来の boid/<id8> 決め打ちでは
# `no_pr` で誤 abort する。 detached HEAD や resolve 失敗時は
# 旧来の boid/<id8> にフォールバックする。
LEGACY_BRANCH="boid/${TASK_ID:0:8}"
WORKTREE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ -z "${WORKTREE_BRANCH}" ] || [ "${WORKTREE_BRANCH}" = "HEAD" ]; then
    BRANCH="${LEGACY_BRANCH}"
else
    BRANCH="${WORKTREE_BRANCH}"
fi
echo "[auto-merge] task=${TASK_ID} branch=${BRANCH} (legacy=${LEGACY_BRANCH})" >&2

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
lookup_pr() {
    # lookup_pr <branch>
    gh pr list --head "$1" --state all \
        --json number,url,state \
        --jq '[.[] | select(.state == "OPEN" or .state == "MERGED")] | sort_by(.state == "OPEN" | not) | .[0]' \
        2>/dev/null || echo ""
}

PR_INFO=$(lookup_pr "${BRANCH}")

# worktree branch で見つからず、 legacy (boid/<id8>) と異なる場合は legacy も試す
if { [ -z "${PR_INFO}" ] || [ "${PR_INFO}" = "null" ]; } && [ "${BRANCH}" != "${LEGACY_BRANCH}" ]; then
    echo "[auto-merge] no PR for ${BRANCH}; falling back to ${LEGACY_BRANCH}" >&2
    FALLBACK_INFO=$(lookup_pr "${LEGACY_BRANCH}")
    if [ -n "${FALLBACK_INFO}" ] && [ "${FALLBACK_INFO}" != "null" ]; then
        PR_INFO="${FALLBACK_INFO}"
        BRANCH="${LEGACY_BRANCH}"
    fi
fi

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
