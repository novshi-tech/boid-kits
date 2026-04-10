#!/usr/bin/env bash
# github-auto-merge script: auto-merge
#
# task_done イベントで発火する。
# 完了タスクの PR を自動マージし、コンフリクトのあるオープン PR に対して解消タスクを登録する。
#
# gate として実行される。タスク JSON は stdin から受け取る。
#
# 環境変数:
#   BOID_MERGE_POLL_RETRIES  mergeable ポーリングの最大リトライ回数（デフォルト 6）
#   BOID_MERGE_POLL_INTERVAL  ポーリング間隔（秒、デフォルト 10）

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

PROJECT_ID=$(printf '%s' "${TASK_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
payload = data.get('payload', {}) or {}
print(payload.get('_trigger', {}).get('project_id', '') or '')
" 2>/dev/null || true)

if [ -z "${TASK_ID}" ]; then
    echo "[auto-merge] ERROR: could not determine TASK_ID from payload"
    exit 0
fi

BRANCH="boid/${TASK_ID:0:8}"
echo "[auto-merge] task=${TASK_ID} project=${PROJECT_ID} branch=${BRANCH}"

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
        'conflicts': [],
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
    echo "[auto-merge] PR already merged, proceeding to conflict check"
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

        # マージ失敗の場合はコンフリクトチェックをスキップ（main は変更されていないため）
        export PR_NUMBER PR_URL BRANCH MERGE_STATUS MERGE_ERROR
        update_task_payload "${TASK_ID}" "$(python3 - <<'PYEOF'
import os, json

pr_number = int(os.environ.get('PR_NUMBER', '0'))
merge_error = os.environ.get('MERGE_ERROR', '') or None

print(json.dumps({
    'artifact': {
        'pr': {
            'number': pr_number,
            'url': os.environ.get('PR_URL', ''),
            'branch': os.environ.get('BRANCH', ''),
            'merged': False,
            'error': merge_error,
        },
        'conflicts': [],
    },
}))
PYEOF
)"
        exit 0
    fi
fi

# --- 4. オープン PR のコンフリクト検出 ---
MAX_RETRIES="${BOID_MERGE_POLL_RETRIES:-6}"
INTERVAL="${BOID_MERGE_POLL_INTERVAL:-10}"

echo "[auto-merge] polling for open PR mergeable status (max_retries=${MAX_RETRIES} interval=${INTERVAL}s)"

OPEN_PRS_JSON="[]"
UNKNOWN_COUNT=0
for i in $(seq 1 "${MAX_RETRIES}"); do
    OPEN_PRS_JSON=$(gh pr list --state open \
        --json number,headRefName,title,url,mergeable 2>/dev/null || echo "[]")

    UNKNOWN_COUNT=$(printf '%s' "${OPEN_PRS_JSON}" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
print(sum(1 for p in prs if p.get('mergeable') == 'UNKNOWN'))
")

    if [ "${UNKNOWN_COUNT}" -eq 0 ]; then
        echo "[auto-merge] all PR mergeable statuses resolved (attempt ${i}/${MAX_RETRIES})"
        break
    fi

    echo "[auto-merge] ${UNKNOWN_COUNT} PR(s) still UNKNOWN, triggering recalculation (attempt ${i}/${MAX_RETRIES})"

    while IFS= read -r num; do
        [ -z "${num}" ] && continue
        gh pr view "${num}" --json mergeable >/dev/null 2>&1 || true
    done < <(printf '%s' "${OPEN_PRS_JSON}" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for p in prs:
    if p.get('mergeable') == 'UNKNOWN':
        print(p['number'])
")

    if [ "${i}" -lt "${MAX_RETRIES}" ]; then
        sleep "${INTERVAL}"
    fi
done

if [ "${UNKNOWN_COUNT}" -gt 0 ]; then
    echo "[auto-merge] WARNING: ${UNKNOWN_COUNT} PR(s) still UNKNOWN after ${MAX_RETRIES} retries, skipping"
fi

# --- 5. コンフリクト解消タスク作成 ---
CONFLICT_PRS_JSON=$(printf '%s' "${OPEN_PRS_JSON}" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
print(json.dumps([p for p in prs if p.get('mergeable') == 'CONFLICTING']))
")

CONFLICT_COUNT=$(printf '%s' "${CONFLICT_PRS_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "[auto-merge] ${CONFLICT_COUNT} conflicting PR(s) found"

CONFLICTS_FILE=$(mktemp /tmp/boid-auto-merge-conflicts.XXXXXX)
echo "[]" > "${CONFLICTS_FILE}"

if [ "${CONFLICT_COUNT}" -gt 0 ]; then
    # 並行 rebase の連鎖を防ぐため、タスクは1つだけ作成
    export PROJECT_ID CONFLICT_PRS_JSON
    python3 - <<'PYEOF' > "${CONFLICTS_FILE}"
import os, json, subprocess, sys

project_id = os.environ.get('PROJECT_ID', '')
conflict_prs = json.loads(os.environ.get('CONFLICT_PRS_JSON', '[]'))

results = []
for i, pr in enumerate(conflict_prs):
    pr_number = pr['number']
    pr_url = pr['url']
    pr_title = pr['title']
    head_branch = pr['headRefName']

    task_id = ''
    if i == 0:
        task_body = {
            "project_id": project_id,
            "behavior": "dev",
            "auto_start": True,
            "title": f"マージコンフリクト解消: {pr_title} (#{pr_number})",
            "description": (
                f"PR #{pr_number} ({pr_url}) のブランチ {head_branch} にマージコンフリクトが発生している。\n\n"
                f"手順:\n"
                f"1. git fetch origin {head_branch}\n"
                f"2. git checkout {head_branch}\n"
                f"3. git rebase origin/main\n"
                f"4. コンフリクトを解消\n"
                f"5. git push --force-with-lease origin {head_branch}\n\n"
                f"元の PR が自動的に更新される。"
            )
        }

        try:
            proc = subprocess.run(
                ['boid', 'task', 'create'],
                input=json.dumps(task_body),
                capture_output=True,
                text=True
            )
            if proc.returncode == 0 and proc.stdout.strip():
                created = json.loads(proc.stdout.strip())
                task_id = created.get('id', '')
                print(f"[auto-merge] created resolution task {task_id} for PR #{pr_number}", file=sys.stderr)
            else:
                print(f"[auto-merge] ERROR: boid task create failed for PR #{pr_number}: {proc.stderr}", file=sys.stderr)
        except Exception as e:
            print(f"[auto-merge] ERROR: exception creating task for PR #{pr_number}: {e}", file=sys.stderr)

    results.append({
        'pr_number': pr_number,
        'pr_url': pr_url,
        'branch': head_branch,
        'title': pr_title,
        'resolution_task_id': task_id,
    })

print(json.dumps(results))
PYEOF
fi

# --- 6. artifact 出力 ---
export PR_NUMBER PR_URL BRANCH MERGE_STATUS MERGE_ERROR
update_task_payload "${TASK_ID}" "$(python3 - "${CONFLICTS_FILE}" <<'PYEOF'
import os, json, sys

conflicts_file = sys.argv[1]
with open(conflicts_file) as f:
    conflicts = json.load(f)

pr_number = int(os.environ.get('PR_NUMBER', '0'))
pr_url = os.environ.get('PR_URL', '')
branch = os.environ.get('BRANCH', '')
merge_status = os.environ.get('MERGE_STATUS', '')
merge_error_str = os.environ.get('MERGE_ERROR', '')
merge_error = merge_error_str if merge_error_str else None

print(json.dumps({
    'artifact': {
        'pr': {
            'number': pr_number,
            'url': pr_url,
            'branch': branch,
            'merged': merge_status in ('merged', 'already_merged'),
            'error': merge_error,
        },
        'conflicts': conflicts,
    },
}))
PYEOF
)"

rm -f "${CONFLICTS_FILE}"

echo "[auto-merge] done"
