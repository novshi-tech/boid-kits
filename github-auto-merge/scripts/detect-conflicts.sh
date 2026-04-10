#!/usr/bin/env bash
# github-auto-merge script: detect-conflicts
#
# open PR を走査し、コンフリクトのある PR に対して解消タスクを登録する。
# イベント駆動なし。cron または手動で起動する。
#
# gate として実行される。タスク JSON は stdin から受け取る。
#
# dedup: boid task import の remote_id + datasource_id で DB の UNIQUE 制約に任せる。
# 同じ PR に対する解消タスクが既に存在する場合は skip される。
#
# 環境変数:
#   BOID_MERGE_POLL_RETRIES  mergeable ポーリングの最大リトライ回数（デフォルト 6）
#   BOID_MERGE_POLL_INTERVAL  ポーリング間隔（秒、デフォルト 10）

set -euo pipefail

echo "[detect-conflicts] starting"

# --- gate は stdin 経由でタスク JSON を受け取る ---
TASK_JSON=$(cat)

# --- helper: boid task update でペイロードを更新 ---
update_task_payload() {
    local task_id="$1"
    local payload_json="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/boid-detect-conflicts-payload.XXXXXX)
    printf '%s' "${payload_json}" > "${tmpfile}"
    boid task update "${task_id}" --payload-file "${tmpfile}" 2>&1 || echo "[detect-conflicts] WARNING: boid task update failed" >&2
    rm -f "${tmpfile}"
}

# --- 1. タスク情報の取得 ---
SELF_TASK_ID=$(printf '%s' "${TASK_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('id', '') or '')
" 2>/dev/null || true)

PROJECT_ID=$(printf '%s' "${TASK_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('project_id', '') or '')
" 2>/dev/null || true)

if [ -z "${PROJECT_ID}" ]; then
    echo "[detect-conflicts] ERROR: could not determine PROJECT_ID from task JSON"
    exit 0
fi

echo "[detect-conflicts] project=${PROJECT_ID}"

# --- 2. オープン PR の mergeable ステータスをポーリング ---
MAX_RETRIES="${BOID_MERGE_POLL_RETRIES:-6}"
INTERVAL="${BOID_MERGE_POLL_INTERVAL:-10}"

echo "[detect-conflicts] polling for open PR mergeable status (max_retries=${MAX_RETRIES} interval=${INTERVAL}s)"

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
        echo "[detect-conflicts] all PR mergeable statuses resolved (attempt ${i}/${MAX_RETRIES})"
        break
    fi

    echo "[detect-conflicts] ${UNKNOWN_COUNT} PR(s) still UNKNOWN, triggering recalculation (attempt ${i}/${MAX_RETRIES})"

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
    echo "[detect-conflicts] WARNING: ${UNKNOWN_COUNT} PR(s) still UNKNOWN after ${MAX_RETRIES} retries, skipping"
fi

# --- 3. コンフリクト PR の抽出 ---
CONFLICT_PRS_JSON=$(printf '%s' "${OPEN_PRS_JSON}" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
print(json.dumps([p for p in prs if p.get('mergeable') == 'CONFLICTING']))
")

CONFLICT_COUNT=$(printf '%s' "${CONFLICT_PRS_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "[detect-conflicts] ${CONFLICT_COUNT} conflicting PR(s) found"

# --- 4. コンフリクト解消タスク作成（boid task import で dedup） ---
RESULTS_FILE=$(mktemp /tmp/boid-detect-conflicts-results.XXXXXX)
echo "[]" > "${RESULTS_FILE}"

if [ "${CONFLICT_COUNT}" -gt 0 ]; then
    # 並行 rebase の連鎖を防ぐため、タスクは1つだけ作成（最初の conflicting PR のみ）
    export PROJECT_ID CONFLICT_PRS_JSON RESULTS_FILE
    python3 - <<'PYEOF'
import os, json, subprocess, sys

project_id = os.environ.get('PROJECT_ID', '')
conflict_prs = json.loads(os.environ.get('CONFLICT_PRS_JSON', '[]'))
results_file = os.environ.get('RESULTS_FILE', '')

results = []
for i, pr in enumerate(conflict_prs):
    pr_number = pr['number']
    pr_url = pr['url']
    pr_title = pr['title']
    head_branch = pr['headRefName']

    task_id = ''
    status = 'skipped'

    if i == 0:
        import_line = json.dumps({
            "project_id": project_id,
            "behavior": "dev",
            "auto_start": True,
            "remote_id": f"pr-{pr_number}",
            "datasource_id": "github-auto-merge",
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
            ),
        })

        try:
            proc = subprocess.run(
                ['boid', 'task', 'import', '--datasource', 'github-auto-merge'],
                input=import_line,
                capture_output=True,
                text=True,
            )
            output = proc.stdout.strip()
            # boid task import outputs: "Created: N, Skipped: N, Errors: N"
            if proc.returncode == 0:
                if 'Created: 1' in output:
                    status = 'created'
                    print(f"[detect-conflicts] created resolution task for PR #{pr_number}", file=sys.stderr)
                elif 'Skipped: 1' in output:
                    status = 'already_exists'
                    print(f"[detect-conflicts] resolution task already exists for PR #{pr_number}, skipped", file=sys.stderr)
                else:
                    print(f"[detect-conflicts] boid task import result for PR #{pr_number}: {output}", file=sys.stderr)
                    status = 'unknown'
            else:
                print(f"[detect-conflicts] ERROR: boid task import failed for PR #{pr_number}: {proc.stderr}", file=sys.stderr)
                status = 'error'
        except Exception as e:
            print(f"[detect-conflicts] ERROR: exception importing task for PR #{pr_number}: {e}", file=sys.stderr)
            status = 'error'

    results.append({
        'pr_number': pr_number,
        'pr_url': pr_url,
        'branch': head_branch,
        'title': pr_title,
        'status': status,
    })

with open(results_file, 'w') as f:
    json.dump(results, f)
PYEOF
fi

# --- 5. artifact 出力 ---
if [ -n "${SELF_TASK_ID}" ]; then
    update_task_payload "${SELF_TASK_ID}" "$(python3 - "${RESULTS_FILE}" <<'PYEOF'
import json, sys

results_file = sys.argv[1]
with open(results_file) as f:
    conflicts = json.load(f)

print(json.dumps({
    'artifact': {
        'conflicts': conflicts,
    },
}))
PYEOF
)"
fi

rm -f "${RESULTS_FILE}"

echo "[detect-conflicts] done"
