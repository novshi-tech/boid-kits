#!/usr/bin/env bash
# github-pr-verification gate: pr-verify
#
# executing ステートでのみ動作する。
# task が worktree 内の場合（boid/<task_id[:8]> ブランチが存在）以下を実行:
#   1. git push (git-cmd ホストコマンド経由でホスト上の worktree に対して実行)
#   2. GitHub PR の作成（既存 PR がある場合はスキップ）
#   3. GitHub Actions の完了を待機し、結果を verification として payload に出力
#

# 【one-shot-feedback との連携】
#   verification findings を payload に出力することで、
#   one-shot-feedback ステートマシンの自己ループ条件を駆動できる:
#     - findings すべて resolved または verification なし → executing → done
#     - findings に open あり → executing → executing (修正ループ)
#
# 環境変数:
#   BOID_WORKTREE_ROOT   ワークツリーのルートディレクトリ（kit env で設定済み）
#   BOID_PR_VERIFY_TIMEOUT  CI 待機の最大ループ回数（1 回 = 10 秒、デフォルト 180 = 30 分）

set -euo pipefail

OUTPUT_DIR="/tmp/.boid/output"
PATCH_FILE="${OUTPUT_DIR}/payload_patch.yaml"

# NOTE: exec 1>&2 は削除済み。
# stdout は /tmp/boid-output にキャプチャされ job output に残るため、
# gate の動作ログが常に可視化される。
# payload_patch.yaml が存在する場合は EXIT trap がそちらを優先するため
# verification findings の保存には影響しない。

# --- task 情報取得 ---
TASK_JSON=$(cat)
TASK_ID=$(printf '%s' "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
PROJECT_ID=$(printf '%s' "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['project_id'])")
TASK_TITLE=$(printf '%s' "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title','') or '')")

TASK_SHORT="${TASK_ID:0:8}"
BRANCH="boid/${TASK_SHORT}"
WORKTREE_ROOT="${BOID_WORKTREE_ROOT:-}"
WORKTREE_PATH="${WORKTREE_ROOT}/${PROJECT_ID}/${TASK_SHORT}"

echo "[pr-verify] task=${TASK_SHORT} branch=${BRANCH}"

# --- diagnostic 蓄積（findings に含めるためのバッファ）---
# 各分岐で観測した状態を DIAG に追記し、最終的に findings の message に含める。
DIAG=""
diag() {
    DIAG+="${1}"$'\n'
}
diag "task_short=${TASK_SHORT}"
diag "branch=${BRANCH}"
diag "worktree_path=${WORKTREE_PATH}"

# --- worktree 検出 ---
# git-cmd は broker 経由でホスト上の /usr/bin/git を実行する。
# broker はホスト上で動くため WORKTREE_PATH の FS にアクセスできる。
REMOTE_URL=$(git-cmd -C "${WORKTREE_PATH}" remote get-url origin 2>/dev/null || true)
diag "remote_url=${REMOTE_URL:-empty}"
if [ -z "$REMOTE_URL" ]; then
    echo "[pr-verify] worktree not found at ${WORKTREE_PATH}, skipping"
    exit 0
fi

# --- worktree HEAD と origin の状態を記録 ---
LOCAL_HEAD=$(git-cmd -C "${WORKTREE_PATH}" rev-parse HEAD 2>/dev/null || echo "?")
ORIGIN_HEAD=$(git-cmd -C "${WORKTREE_PATH}" rev-parse "origin/${BRANCH}" 2>/dev/null || echo "?")
diag "local_head=${LOCAL_HEAD}"
diag "origin_head=${ORIGIN_HEAD}"
COMMITS_AHEAD=$(git-cmd -C "${WORKTREE_PATH}" rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo "?")
diag "commits_ahead=${COMMITS_AHEAD}"

# --- GitHub リポジトリ確認 ---
if ! printf '%s' "$REMOTE_URL" | grep -q 'github\.com'; then
    echo "[pr-verify] not a GitHub remote (${REMOTE_URL}), skipping"
    exit 0
fi

# --- push 前に既存の最新 CI run ID を記録 ---
# rework サイクルで前サイクルの stale run を拾わないために、
# push 前の最新 run ID を記録しておく。
PREV_RUN_ID=$(gh run list --branch "${BRANCH}" --limit 1 \
    --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || true)
echo "[pr-verify] previous run ID: ${PREV_RUN_ID:-none}"
diag "prev_run_id=${PREV_RUN_ID:-none}"

# --- git push ---
echo "[pr-verify] git push origin ${BRANCH}"
PUSH_EXIT=0
PUSH_OUT=$(git-cmd -C "${WORKTREE_PATH}" push origin "${BRANCH}" 2>&1) || PUSH_EXIT=$?
diag "push_exit=${PUSH_EXIT}"
diag "push_out_first10=$(printf '%s' "$PUSH_OUT" | head -10 | tr '\n' '|')"

# emit_findings: diag を含めて findings を出力するヘルパー
emit_findings() {
    local msg="$1"
    local status="$2"
    {
        printf 'payload_patch:\n'
        printf '  verification:\n'
        printf '    findings:\n'
        printf '      - status: %s\n' "$status"
        printf '        message: |\n'
        printf '          %s\n' "$msg"
        printf '          DIAGNOSTIC:\n'
        printf '%s' "$DIAG" | sed 's/^/            /'
    } > "${PATCH_FILE}"
}

# push が up-to-date の場合: 新しいコミットが push されていない
if printf '%s' "$PUSH_OUT" | grep -qiE 'up-to-date|everything up-to-date|nothing to push'; then
    echo "[pr-verify] branch already up-to-date on remote"
    diag "branch=up_to_date"
    DIRTY=$(git-cmd -C "${WORKTREE_PATH}" status --porcelain 2>/dev/null || true)
    diag "dirty=$(printf '%s' "$DIRTY" | wc -l)_lines"
    if [ -n "$DIRTY" ]; then
        echo "[pr-verify] uncommitted changes detected in worktree"
        emit_findings "Uncommitted changes detected in worktree. Commit and push your changes before CI can verify them." "open"
    elif [ -n "$PREV_RUN_ID" ]; then
        # 新しいコミットはないが、前回の CI run がある場合はその結果を確認する
        echo "[pr-verify] checking previous CI run ${PREV_RUN_ID}"
        PREV_STATUS=$(gh run view "${PREV_RUN_ID}" \
            --json status,conclusion \
            --jq '"\(.status)|\(.conclusion // "")"' 2>/dev/null || echo "|")
        PREV_RUN_STATUS="${PREV_STATUS%%|*}"
        PREV_CONCLUSION="${PREV_STATUS#*|}"
        diag "prev_run_status=${PREV_RUN_STATUS}"
        diag "prev_conclusion=${PREV_CONCLUSION}"
        if [ "$PREV_RUN_STATUS" = "completed" ] && [ "$PREV_CONCLUSION" = "success" ]; then
            echo "[pr-verify] previous CI run passed, no new commits needed"
            PR_URL=$(gh pr list --head "${BRANCH}" --json url \
                --jq '.[0].url // ""' 2>/dev/null || true)
            emit_findings "GitHub Actions passed (${PR_URL:-no PR})" "resolved"
        else
            echo "[pr-verify] previous CI run not successful (status=${PREV_RUN_STATUS}, conclusion=${PREV_CONCLUSION})"
            emit_findings "No new commits were added since the last rework cycle. The rework must produce at least one new commit with changes." "open"
        fi
    else
        echo "[pr-verify] no new commits and no previous CI run"
        emit_findings "No new commits were added since the last rework cycle. The rework must produce at least one new commit with changes." "open"
    fi
    exit 0
fi

# push が失敗した場合（up-to-date 以外の失敗）
if [ "${PUSH_EXIT}" -ne 0 ]; then
    echo "[pr-verify] git push failed (exit=${PUSH_EXIT}): ${PUSH_OUT}"
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  verification:
    findings:
      - message: "git push failed for branch ${BRANCH}: ${PUSH_OUT}"
        status: open
EOF
    exit 0
fi

echo "[pr-verify] push successful"

# --- PR の検索または作成 ---
PR_URL=$(gh pr list --head "${BRANCH}" --json url \
    --jq '.[0].url // ""' 2>/dev/null || true)

if [ -z "$PR_URL" ]; then
    echo "[pr-verify] creating PR for ${BRANCH}"
    GH_OUT=$(gh pr create \
        --head "${BRANCH}" \
        --title "${TASK_TITLE:-Task ${TASK_SHORT}}" \
        --body "boid task: ${TASK_ID}" 2>/dev/null || true)
    # gh pr create outputs the PR URL as the last line on success
    PR_URL=$(echo "${GH_OUT}" | grep -E '^https://' | tail -1 || true)
fi

if [ -z "$PR_URL" ]; then
    echo "[pr-verify] could not create PR (no commits ahead of base?), skipping"
    exit 0
fi

echo "[pr-verify] PR: ${PR_URL}"

# --- GitHub Actions の検索（push 後のトリガー遅延を考慮してリトライ）---
# push 直後は Actions がまだトリガーされていないことがあるため、
# BOID_PR_VERIFY_RUN_DETECT_RETRY 回（デフォルト 12 回 × 10 秒 = 2 分）リトライする。
# PREV_RUN_ID と異なる run のみを対象にすることで、前サイクルの stale run を回避する。
RUN_DETECT_RETRY="${BOID_PR_VERIFY_RUN_DETECT_RETRY:-12}"
RUN_ID=""

echo "[pr-verify] waiting for new CI run on branch ${BRANCH} (prev=${PREV_RUN_ID:-none}, max ${RUN_DETECT_RETRY} attempts)"
for i in $(seq 1 "${RUN_DETECT_RETRY}"); do
    CANDIDATE=$(gh run list --branch "${BRANCH}" --limit 1 \
        --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || true)
    if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$PREV_RUN_ID" ]; then
        RUN_ID="$CANDIDATE"
        echo "[pr-verify] found new CI run ${RUN_ID} (attempt ${i})"
        break
    fi
    echo "[pr-verify] no new CI run yet (candidate=${CANDIDATE:-none}), waiting 10s (attempt ${i}/${RUN_DETECT_RETRY})"
    sleep 10
done

if [ -z "$RUN_ID" ]; then
    echo "[pr-verify] no CI runs found after ${RUN_DETECT_RETRY} attempts (no GitHub Actions configured?)"
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  verification:
    findings:
      - message: "PR created: ${PR_URL} (no GitHub Actions configured)"
        status: resolved
EOF
    exit 0
fi

# --- CI 完了待機 ---
# BOID_PR_VERIFY_TIMEOUT × 10 秒のタイムアウト（デフォルト 30 分）
# one-shot-feedback を使う場合、CI が失敗しても dispatch loop が
# エージェントを再実行するため、ここでは 1 回の結果を返せば十分。
TIMEOUT="${BOID_PR_VERIFY_TIMEOUT:-180}"
CONCLUSION=""
RUN_STATUS=""

echo "[pr-verify] waiting for CI run ${RUN_ID} (timeout=${TIMEOUT}×10s)"

for i in $(seq 1 "${TIMEOUT}"); do
    STATUS=$(gh run view "${RUN_ID}" \
        --json status,conclusion \
        --jq '"\(.status)|\(.conclusion // "")"' 2>/dev/null || echo "|")
    RUN_STATUS="${STATUS%%|*}"
    CONCLUSION="${STATUS#*|}"

    if [ "$RUN_STATUS" = "completed" ]; then
        echo "[pr-verify] CI completed: conclusion=${CONCLUSION}"
        break
    fi

    if [ "$i" -eq "${TIMEOUT}" ]; then
        echo "[pr-verify] CI timed out after $((TIMEOUT * 10))s"
    fi
    sleep 10
done

if [ "$RUN_STATUS" != "completed" ]; then
    echo "[pr-verify] CI not completed, no findings written"
    exit 0
fi

# --- verification findings 出力 ---
if [ "$CONCLUSION" = "success" ]; then
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  verification:
    findings:
      - message: "GitHub Actions passed (${PR_URL})"
        status: resolved
EOF
else
    # 失敗したジョブ名 + 失敗ステップ名を収集
    FAILED_JOBS=$(gh run view "${RUN_ID}" --json jobs \
        --jq '[.jobs[] | select(.conclusion != null and .conclusion != "success") |
              "\(.name) [steps: \([.steps[] | select(.conclusion != null and .conclusion != "success") | .name] | join(", "))]"
             ] | join("; ")' \
        2>/dev/null || echo "unknown")
    echo "[pr-verify] failed jobs: ${FAILED_JOBS}"

    # 失敗ステップのログを収集（末尾100行）
    FAILED_LOG_FILE=$(mktemp /tmp/boid-pr-verify-log.XXXXXX)
    gh run view "${RUN_ID}" --log-failed 2>/dev/null | tail -n 100 > "${FAILED_LOG_FILE}" || true
    echo "[pr-verify] collected $(wc -l < "${FAILED_LOG_FILE}") log lines"

    # Python で YAML を安全に生成（multiline メッセージのエスケープ対策）
    export FAILED_JOBS PR_URL CONCLUSION FAILED_LOG_FILE
    python3 - <<'PYEOF' > "${PATCH_FILE}"
import os

failed_jobs = os.environ.get('FAILED_JOBS', 'unknown')
pr_url = os.environ.get('PR_URL', '')
conclusion = os.environ.get('CONCLUSION', '')
log_file = os.environ.get('FAILED_LOG_FILE', '')

failed_log = ''
if log_file and os.path.exists(log_file):
    with open(log_file) as f:
        failed_log = f.read().strip()

parts = [
    f"GitHub Actions {conclusion} on {pr_url}",
    f"Failed: {failed_jobs}",
]
if failed_log:
    parts += ["", "Log (last 100 lines):", failed_log]

message = "\n".join(parts)

try:
    import yaml
    data = {
        'payload_patch': {
            'verification': {
                'findings': [{'message': message, 'status': 'open'}]
            }
        }
    }
    print(yaml.dump(data, default_flow_style=False, allow_unicode=True))
except ImportError:
    # PyYAML がない場合: 改行を \n にエスケープして quoted string として出力
    escaped = message.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    print(f'payload_patch:\n  verification:\n    findings:\n      - message: "{escaped}"\n        status: open')
PYEOF
    rm -f "${FAILED_LOG_FILE}"
fi
