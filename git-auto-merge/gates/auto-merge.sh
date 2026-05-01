#!/usr/bin/env bash
# auto-merge gate (phase: exit)
#
# task の executing 退場時に発火する host gate。
# BASE branch が checked out されている worktree W で `git merge --no-ff` を
# 実行し、HEAD / index / working tree を一括で前進させる。
#
# conflict や前提条件違反は exit code 非ゼロで終了し、
# state machine 側で job_failed → aborted に遷移させる。
#
# 失敗パターン (artifact.error に出してから exit 1):
#   - base_not_checked_out: BASE がどこにも checkout されていない
#   - primary_busy:         対象 worktree が dirty / merge / rebase 中
#   - merge_conflict:       実マージで衝突 (dry-run / 実マージ問わず)
#
# stdin: PayloadJSON (このスクリプトでは使わない)
# stdout: payload_patch (JSON)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

# stdin を読み捨て (PayloadJSON は未使用)
cat >/dev/null || true

TASK_ID="${BOID_TASK_ID:-}"
if [ -z "${TASK_ID}" ]; then
    echo "[auto-merge] ERROR: BOID_TASK_ID is not set" >&2
    exit 1
fi
TASK_BRANCH="boid/${TASK_ID:0:8}"

BASE=$(detect_base_branch "${TASK_BRANCH}")
echo "[auto-merge] task=${TASK_ID} branch=${TASK_BRANCH} base=${BASE}" >&2

# emit_artifact <merged: true|false> [error] [merge_sha]
emit_artifact() {
    export BASE TASK_BRANCH AM_MERGED="$1" AM_ERROR="${2:-}" AM_SHA="${3:-}"
    python3 - <<'PYEOF'
import os, json

am = {
    'merged': os.environ['AM_MERGED'] == 'true',
    'base_branch': os.environ['BASE'],
    'task_branch': os.environ['TASK_BRANCH'],
}
if os.environ.get('AM_ERROR'):
    am['error'] = os.environ['AM_ERROR']
if os.environ.get('AM_SHA'):
    am['merge_commit'] = os.environ['AM_SHA']

patch = {'payload_patch': {'artifact': {'auto-merge': am}}}
print(json.dumps(patch, ensure_ascii=False))
PYEOF
}

# --- mergeable dry-run check (git merge-tree) ---
# git 2.38+ の新モード:
#   exit 0: conflict なし
#   exit 1: conflict あり
#   exit 2+: スクリプトエラー
MERGE_TREE_OUT=""
MERGE_TREE_EXIT=0
MERGE_TREE_OUT=$(git merge-tree "${BASE}" "${TASK_BRANCH}" 2>&1) || MERGE_TREE_EXIT=$?

if [ "${MERGE_TREE_EXIT}" -ge 2 ]; then
    echo "[auto-merge] ERROR: git merge-tree failed (exit=${MERGE_TREE_EXIT})" >&2
    printf '%s\n' "${MERGE_TREE_OUT}" >&2
    emit_artifact false merge_tree_error
    exit 1
fi

if [ "${MERGE_TREE_EXIT}" -eq 1 ]; then
    echo "[auto-merge] conflict detected with base branch ${BASE}" >&2
    printf '%s\n' "${MERGE_TREE_OUT}" >&2
    emit_artifact false merge_conflict
    exit 1
fi

# --- flock で排他ロック取得 (リポジトリ単位で直列化) ---
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
case "${GIT_COMMON_DIR}" in
    /*) ;;
    *) GIT_COMMON_DIR="$(cd "${GIT_COMMON_DIR}" && pwd)" ;;
esac
LOCK_FILE="${GIT_COMMON_DIR}/boid-auto-merge.lock"
echo "[auto-merge] acquiring lock: ${LOCK_FILE}" >&2
exec 9>"${LOCK_FILE}"
flock 9
echo "[auto-merge] lock acquired" >&2

# --- BASE が checked out されている worktree W を探す ---
W=$(git worktree list --porcelain | awk -v base="${BASE}" '
    BEGIN { RS = ""; FS = "\n" }
    {
        path = ""; on_base = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^worktree /) {
                path = substr($i, length("worktree ") + 1)
            } else if ($i == "branch refs/heads/" base) {
                on_base = 1
            }
        }
        if (on_base && path != "") { print path; exit }
    }
')

if [ -z "${W}" ]; then
    echo "[auto-merge] ERROR: base branch '${BASE}' is not checked out in any worktree" >&2
    emit_artifact false base_not_checked_out
    exit 1
fi
echo "[auto-merge] target worktree: ${W}" >&2

# --- W が dirty でないか ---
if [ -n "$(git -C "${W}" status --porcelain)" ]; then
    echo "[auto-merge] ERROR: worktree '${W}' has uncommitted changes" >&2
    emit_artifact false primary_busy
    exit 1
fi

# --- W で merge / rebase / cherry-pick / revert / am 等が進行中でないか ---
GIT_DIR_W=$(git -C "${W}" rev-parse --git-dir)
case "${GIT_DIR_W}" in
    /*) ;;
    *) GIT_DIR_W="${W}/${GIT_DIR_W}" ;;
esac
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [ -e "${GIT_DIR_W}/${marker}" ]; then
        echo "[auto-merge] ERROR: worktree '${W}' has in-progress operation (${marker})" >&2
        emit_artifact false primary_busy
        exit 1
    fi
done

# --- W で直接 merge ---
if ! git -C "${W}" merge --no-ff "${TASK_BRANCH}" \
        -m "Merge ${TASK_BRANCH} into ${BASE}" >&2; then
    # 衝突マーカを残さないよう abort してから出る
    git -C "${W}" merge --abort >/dev/null 2>&1 || true
    echo "[auto-merge] merge failed: late_conflict" >&2
    emit_artifact false late_conflict
    exit 1
fi

MERGE_SHA=$(git -C "${W}" rev-parse HEAD)
echo "[auto-merge] merge commit: ${MERGE_SHA}" >&2
emit_artifact true "" "${MERGE_SHA}"
