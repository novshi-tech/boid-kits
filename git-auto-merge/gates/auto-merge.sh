#!/usr/bin/env bash
# auto-merge gate (on: done, phase: entry)
#
# host gate (kit.yaml で host: true) として動く前提で、BASE branch が
# checked out されている worktree W で直接 `git merge --no-ff` を行い
# HEAD / index / working tree を一括で前進させる。
#
# 旧設計 (`/tmp` に detached worktree → merge → `git update-ref`) は廃止。
# `update-ref` は同名ブランチが別 worktree で checkout 中でも通るが、
# その worktree は HEAD だけ動いて index / working tree が取り残される
# desync 状態に陥り、ユーザーが「謎の差分」を `git add -A && git commit`
# でクリーンアップするとマージを丸ごと revert する事故を生む。host gate
# になり fs フルアクセスが得られた今は、この迂回を残す動機が無い。
#
# 失敗パターンは artifact.error に出して reworking に戻す:
#   - base_not_checked_out: BASE がどこにも checkout されていない
#   - primary_busy:         対象 worktree が dirty / merge / rebase 中
#   - late_conflict:        実マージで衝突
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
# git worktree list --porcelain は各エントリを空行で区切り、
# `worktree <path>` / `branch refs/heads/<name>` などの行で構成される。
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
    exit 0
fi
echo "[auto-merge] target worktree: ${W}" >&2

# --- W が dirty でないか (--porcelain は untracked / staged / unstaged を網羅) ---
if [ -n "$(git -C "${W}" status --porcelain)" ]; then
    echo "[auto-merge] ERROR: worktree '${W}' has uncommitted changes" >&2
    emit_artifact false primary_busy
    exit 0
fi

# --- W で merge / rebase / cherry-pick / revert / am 等が進行中でないか ---
# これらのマーカは worktree 個別の git-dir に置かれる (--git-dir で取れる)。
GIT_DIR_W=$(git -C "${W}" rev-parse --git-dir)
case "${GIT_DIR_W}" in
    /*) ;;
    *) GIT_DIR_W="${W}/${GIT_DIR_W}" ;;
esac
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [ -e "${GIT_DIR_W}/${marker}" ]; then
        echo "[auto-merge] ERROR: worktree '${W}' has in-progress operation (${marker})" >&2
        emit_artifact false primary_busy
        exit 0
    fi
done

# --- W で直接 merge ---
if ! git -C "${W}" merge --no-ff "${TASK_BRANCH}" \
        -m "Merge ${TASK_BRANCH} into ${BASE}" >&2; then
    # 衝突マーカを残さないよう abort してから出る
    git -C "${W}" merge --abort >/dev/null 2>&1 || true
    echo "[auto-merge] merge failed: late_conflict" >&2
    emit_artifact false late_conflict
    exit 0
fi

MERGE_SHA=$(git -C "${W}" rev-parse HEAD)
echo "[auto-merge] merge commit: ${MERGE_SHA}" >&2
emit_artifact true "" "${MERGE_SHA}"
