#!/usr/bin/env bash
# github-pr-verification gate: pr-verify
#
# executing ステートでのみ動作する。
# task が worktree 内の場合（boid/<task_id[:8]> ブランチが存在）以下を実行:
#   1. git push (git-cmd ホストコマンド経由でホスト上の worktree に対して実行)
#   2. GitHub PR の作成（既存 PR がある場合はスキップ）
#   3. GitHub Actions の完了を待機し、結果を verification として payload に出力
#
# 【--repo フラグについて】
#   gate sandbox は /tmp で動作し git リポジトリが存在しないため、
#   gh コマンドは --repo フラグなしでリポジトリを自動検出できない。
#   このスクリプトは git-cmd 経由でリモート URL を取得し、
#   すべての gh コマンドに --repo "${REPO}" を明示的に渡している。
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

# stdout をすべて stderr（端末）にリダイレクト。
# payload_patch はファイルに書き込むため stdout は使用しない。
exec 1>&2

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

# --- worktree 検出 ---
# git-cmd は broker 経由でホスト上の /usr/bin/git を実行する。
# broker はホスト上で動くため WORKTREE_PATH の FS にアクセスできる。
REMOTE_URL=$(git-cmd -C "${WORKTREE_PATH}" remote get-url origin 2>/dev/null || true)
if [ -z "$REMOTE_URL" ]; then
    echo "[pr-verify] worktree not found at ${WORKTREE_PATH}, skipping"
    exit 0
fi

# --- GitHub リポジトリ名を取得 ---
# gate は /tmp で動くため gh コマンドの自動検出ができない。
# リモート URL を解析して --repo フラグ用の "owner/repo" スラグを生成する。
REPO=$(printf '%s' "$REMOTE_URL" | python3 -c "
import sys, re
url = sys.stdin.read().strip()
m = re.search(r'github\.com[:/]([^/]+/[^/?#\s]+?)(?:\.git)?\s*$', url)
print(m.group(1) if m else '')
")
if [ -z "$REPO" ]; then
    echo "[pr-verify] not a GitHub remote (${REMOTE_URL}), skipping"
    exit 0
fi

echo "[pr-verify] repo=${REPO}"

# --- git push ---
echo "[pr-verify] git push origin ${BRANCH}"
PUSH_OUT=$(git-cmd -C "${WORKTREE_PATH}" push origin "${BRANCH}" 2>&1 || true)
PUSH_STATUS=$?
if [ "${PUSH_STATUS}" -ne 0 ]; then
    if printf '%s' "$PUSH_OUT" | grep -qiE 'up-to-date|everything up-to-date|nothing to push'; then
        echo "[pr-verify] branch already up-to-date on remote"
    else
        echo "[pr-verify] git push failed (exit=${PUSH_STATUS}): ${PUSH_OUT}"
        cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  verification:
    findings:
      - message: "git push failed for branch ${BRANCH}"
        status: open
EOF
        exit 0
    fi
fi

# --- PR の検索または作成 ---
# すべての gh コマンドに --repo "${REPO}" を明示指定（/tmp では自動検出不可）
PR_URL=$(gh pr list --repo "${REPO}" --head "${BRANCH}" --json url \
    --jq '.[0].url // ""' 2>/dev/null || true)

if [ -z "$PR_URL" ]; then
    echo "[pr-verify] creating PR for ${BRANCH}"
    PR_URL=$(gh pr create \
        --repo "${REPO}" \
        --head "${BRANCH}" \
        --title "${TASK_TITLE:-Task ${TASK_SHORT}}" \
        --body "boid task: ${TASK_ID}" \
        --json url --jq '.url' 2>/dev/null || true)
fi

if [ -z "$PR_URL" ]; then
    echo "[pr-verify] could not create PR (no commits ahead of base?), skipping"
    exit 0
fi

echo "[pr-verify] PR: ${PR_URL}"

# --- GitHub Actions の検索 ---
RUN_ID=$(gh run list --repo "${REPO}" --branch "${BRANCH}" --limit 1 \
    --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || true)

if [ -z "$RUN_ID" ]; then
    echo "[pr-verify] no CI runs found"
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
    STATUS=$(gh run view "${RUN_ID}" --repo "${REPO}" \
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
    FAILED=$(gh run view "${RUN_ID}" --repo "${REPO}" --json jobs \
        --jq '[.jobs[] | select(.conclusion != null and .conclusion != "success") | .name] | join(", ")' \
        2>/dev/null || echo "unknown")
    cat > "${PATCH_FILE}" <<-EOF
payload_patch:
  verification:
    findings:
      - message: "GitHub Actions ${CONCLUSION} on ${PR_URL}: ${FAILED}"
        status: open
EOF
fi
