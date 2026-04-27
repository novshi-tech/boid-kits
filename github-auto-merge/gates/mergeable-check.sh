#!/usr/bin/env bash
# mergeable-check gate (exit gate on verifying)
#
# verifying 退場時に PR の mergeable ステータスを検証する。
# CONFLICTING なら conflict finding を書き出し、reworking に戻す。
# MERGEABLE/UNKNOWN では自身の subkey を空で更新する。
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
echo "[mergeable-check] task=${TASK_ID} branch=${BRANCH}" >&2

# --- PR の存在確認 ---
PR_INFO=$(gh pr list --head "${BRANCH}" --state open \
    --json number,url \
    --jq '.[0]' \
    2>/dev/null || echo "")

if [ -z "${PR_INFO}" ] || [ "${PR_INFO}" = "null" ]; then
    echo "[mergeable-check] no open PR for branch ${BRANCH}, skipping" >&2
    exit 0
fi

PR_NUMBER=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
PR_URL=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

echo "[mergeable-check] PR #${PR_NUMBER} (${PR_URL})" >&2

# --- mergeable ステータスのポーリング ---
MAX_RETRIES="${BOID_MERGE_POLL_RETRIES:-6}"
INTERVAL="${BOID_MERGE_POLL_INTERVAL:-10}"
MERGEABLE="UNKNOWN"

for i in $(seq 1 "${MAX_RETRIES}"); do
    MERGEABLE=$(gh pr view "${PR_NUMBER}" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")

    if [ "${MERGEABLE}" != "UNKNOWN" ]; then
        echo "[mergeable-check] PR #${PR_NUMBER} mergeable=${MERGEABLE} (attempt ${i}/${MAX_RETRIES})" >&2
        break
    fi

    echo "[mergeable-check] PR #${PR_NUMBER} mergeable=UNKNOWN, retrying (attempt ${i}/${MAX_RETRIES})" >&2

    if [ "${i}" -lt "${MAX_RETRIES}" ]; then
        sleep "${INTERVAL}"
    fi
done

# --- conflict 検出: finding を書き出す ---
if [ "${MERGEABLE}" = "CONFLICTING" ]; then
    echo "[mergeable-check] PR #${PR_NUMBER} has merge conflicts" >&2

    export PR_NUMBER PR_URL BRANCH
    python3 -c "
import os, json

pr_number = int(os.environ['PR_NUMBER'])
pr_url = os.environ['PR_URL']

patch = {
    'payload_patch': {
        'verification': {
            'findings': [{
                'message': (
                    f'PR #{pr_number} ({pr_url}) が base ブランチとマージコンフリクトしています。\n'
                    f'worktree で以下を実行してコンフリクトを解消してください:\n'
                    f'\n'
                    f'  1. git merge origin/main\n'
                    f'  2. コンフリクトを解消\n'
                    f'  3. git add <resolved_files> && git commit\n'
                    f'\n'
                    f'注意:\n'
                    f'  - git rebase は使わないこと（fast-forward 互換な履歴を保つため）\n'
                    f'  - git push は不要（pr-verify gate が自動で push する）\n'
                    f'  - hook role からは git fetch/push が禁止されているため手動で fetch しないこと'
                ),
                'status': 'open',
            }],
        },
    },
}
print(json.dumps(patch, ensure_ascii=False))
"
    exit 0
fi

# --- MERGEABLE / UNKNOWN: 自身の subkey を空で更新 (古い finding をクリア) ---
echo "[mergeable-check] PR #${PR_NUMBER} mergeable=${MERGEABLE}, clearing findings" >&2

python3 -c "
import json

patch = {
    'payload_patch': {
        'verification': {
            'findings': [],
        },
    },
}
print(json.dumps(patch, ensure_ascii=False))
"
