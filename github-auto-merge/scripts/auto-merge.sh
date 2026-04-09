#!/usr/bin/env bash
# github-auto-merge script: auto-merge
#
# task_done イベントで発火する。
# 完了タスクの PR を自動マージし、コンフリクトのあるオープン PR に対して解消タスクを登録する。
#
# 環境変数:
#   BOID_MERGE_POLL_RETRIES  mergeable ポーリングの最大リトライ回数（デフォルト 6）
#   BOID_MERGE_POLL_INTERVAL  ポーリング間隔（秒、デフォルト 10）

set -euo pipefail

OUTPUT_DIR="${HOME}/.boid/output"
PATCH_FILE="${OUTPUT_DIR}/payload_patch.yaml"
CONTEXT_PAYLOAD="${HOME}/.boid/context/payload.yaml"

mkdir -p "${OUTPUT_DIR}"

echo "[auto-merge] starting"

# --- 1. トリガー情報の取得 ---
TASK_ID=""
PROJECT_ID=""

TASK_ID=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(data.get('_trigger', {}).get('task_id', '') or '')
" "${CONTEXT_PAYLOAD}" 2>/dev/null || true)

PROJECT_ID=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(data.get('_trigger', {}).get('project_id', '') or '')
" "${CONTEXT_PAYLOAD}" 2>/dev/null || true)

if [ -z "${TASK_ID}" ]; then
    echo "[auto-merge] ERROR: could not determine TASK_ID from payload"
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  artifact:
    merged_pr:
      number: null
      url: null
      branch: null
      status: "error"
      error: "could not determine TASK_ID from payload"
    conflicts: []
EOF
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
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  artifact:
    merged_pr:
      number: null
      url: null
      branch: "${BRANCH}"
      status: "no_pr"
      error: null
    conflicts: []
EOF
    exit 0
fi

PR_NUMBER=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
PR_URL=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
PR_STATE=$(printf '%s' "${PR_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

echo "[auto-merge] PR #${PR_NUMBER} (${PR_URL}) state=${PR_STATE}"

MERGE_STATUS=""
MERGE_ERROR=""

# --- PR が既にマージ済みの場合 ---
if [ "${PR_STATE}" = "MERGED" ]; then
    echo "[auto-merge] PR already merged, proceeding to conflict check"
    MERGE_STATUS="already_merged"
fi

# --- 3. PR マージ ---
if [ -z "${MERGE_STATUS}" ]; then
    MERGE_STDERR_FILE=$(mktemp /tmp/boid-auto-merge-err.XXXXXX)
    MERGE_EXIT=0

    gh pr merge "${PR_NUMBER}" --merge --delete-branch 2>"${MERGE_STDERR_FILE}" || MERGE_EXIT=$?
    MERGE_STDERR=$(cat "${MERGE_STDERR_FILE}")
    rm -f "${MERGE_STDERR_FILE}"

    if [ "${MERGE_EXIT}" -eq 0 ]; then
        echo "[auto-merge] PR merged successfully"
        MERGE_STATUS="merged"
    else
        echo "[auto-merge] merge failed (exit=${MERGE_EXIT}): ${MERGE_STDERR}"
        MERGE_STATUS="merge_failed"
        MERGE_ERROR="${MERGE_STDERR}"

        # マージ失敗の場合はコンフリクトチェックをスキップ（main は変更されていないため）
        export PR_NUMBER PR_URL BRANCH MERGE_STATUS MERGE_ERROR
        python3 - <<'PYEOF' > "${PATCH_FILE}"
import os, yaml

pr_number_str = os.environ.get('PR_NUMBER', '')
pr_number = int(pr_number_str) if pr_number_str else None
merge_error = os.environ.get('MERGE_ERROR', '') or None

data = {
    'payload_patch': {
        'artifact': {
            'merged_pr': {
                'number': pr_number,
                'url': os.environ.get('PR_URL', ''),
                'branch': os.environ.get('BRANCH', ''),
                'status': os.environ.get('MERGE_STATUS', ''),
                'error': merge_error,
            },
            'conflicts': []
        }
    }
}
print(yaml.dump(data, default_flow_style=False, allow_unicode=True))
PYEOF
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

    # 各 UNKNOWN PR に対して個別リクエスト（再計算トリガー）
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
    # 並行 rebase の連鎖を防ぐため、タスクは1つだけ作成
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
            else:
                print(f"[auto-merge] boid task create failed for PR #{pr_number}: {proc.stderr}", file=sys.stderr)
        except Exception as e:
            print(f"[auto-merge] exception creating task for PR #{pr_number}: {e}", file=sys.stderr)

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
python3 - "${CONFLICTS_FILE}" <<'PYEOF' > "${PATCH_FILE}"
import os, json, sys, yaml

conflicts_file = sys.argv[1]
with open(conflicts_file) as f:
    conflicts = json.load(f)

pr_number_str = os.environ.get('PR_NUMBER', '')
pr_number = int(pr_number_str) if pr_number_str else None
pr_url = os.environ.get('PR_URL', '')
branch = os.environ.get('BRANCH', '')
merge_status = os.environ.get('MERGE_STATUS', '')
merge_error_str = os.environ.get('MERGE_ERROR', '')
merge_error = merge_error_str if merge_error_str else None

data = {
    'payload_patch': {
        'artifact': {
            'merged_pr': {
                'number': pr_number,
                'url': pr_url,
                'branch': branch,
                'status': merge_status,
                'error': merge_error,
            },
            'conflicts': conflicts,
        }
    }
}

print(yaml.dump(data, default_flow_style=False, allow_unicode=True))
PYEOF

rm -f "${CONFLICTS_FILE}"

echo "[auto-merge] done. artifact written to ${PATCH_FILE}"
