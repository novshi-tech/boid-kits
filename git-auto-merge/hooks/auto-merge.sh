#!/usr/bin/env bash
# auto-merge hook (on: done)
#
# done 入場時に flock で排他ロックを取り、detached worktree を /tmp に作って
# --no-ff マージコミットを作成、update-ref で base branch を atomic に更新する。
#
# stdin: PayloadJSON (このスクリプトでは使わない)
# stdout: payload_patch (YAML)

set -euo pipefail

# detect_base_branch <task_branch>
#
# stdout に base branch 名を出力する。
# 1. BOID_BASE_BRANCH env が設定されていればそれを使う。
# 2. 未設定なら git worktree list --porcelain の最初のエントリの branch を採用。
#    ただし task 自身の branch (引数) と一致する場合はスキップして次のエントリを見る。
# 3. 検出できない場合は stderr にエラーを出し、exit 1。
#
# NOTE: 本来は scripts/lib.sh に分離していたが、boid の kit ステージング
# (internal/orchestrator/kit_stage.go) がサブディレクトリを持ち込まないため
# 暫定で inline 化している。kit 全体を bind-mount する改修後に再分離予定。
detect_base_branch() {
    local task_branch="$1"

    if [ -n "${BOID_BASE_BRANCH:-}" ]; then
        printf '%s\n' "${BOID_BASE_BRANCH}"
        return 0
    fi

    local worktree_list
    worktree_list=$(git worktree list --porcelain 2>/dev/null || true)
    if [ -z "${worktree_list}" ]; then
        echo "[git-auto-merge/lib] ERROR: git worktree list failed" >&2
        return 1
    fi

    local base
    base=$(printf '%s\n' "${worktree_list}" | awk -v task="${task_branch}" '
        BEGIN { RS = ""; FS = "\n" }
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^branch refs\/heads\//) {
                    name = substr($i, length("branch refs/heads/") + 1)
                    if (name != task) {
                        print name
                        exit
                    }
                }
            }
        }
    ')

    if [ -z "${base}" ]; then
        echo "[git-auto-merge/lib] ERROR: could not detect base branch from worktree list" >&2
        return 1
    fi

    printf '%s\n' "${base}"
}

# stdin を読み捨て (PayloadJSON は未使用)
cat >/dev/null || true

TASK_ID="${BOID_TASK_ID:-}"
if [ -z "${TASK_ID}" ]; then
    echo "[auto-merge] ERROR: BOID_TASK_ID is not set" >&2
    exit 1
fi

TASK_BRANCH="boid/${TASK_ID:0:8}"
echo "[auto-merge] task=${TASK_ID} branch=${TASK_BRANCH}" >&2

BASE=$(detect_base_branch "${TASK_BRANCH}")
echo "[auto-merge] base=${BASE}" >&2

# --- flock で排他ロック取得 ---
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
# git rev-parse が相対パスを返すことがあるので絶対化する
case "${GIT_COMMON_DIR}" in
    /*) ;;
    *) GIT_COMMON_DIR="$(cd "${GIT_COMMON_DIR}" && pwd)" ;;
esac
LOCK_FILE="${GIT_COMMON_DIR}/boid-auto-merge.lock"
echo "[auto-merge] acquiring lock: ${LOCK_FILE}" >&2
exec 9>"${LOCK_FILE}"
flock 9
echo "[auto-merge] lock acquired" >&2

# --- base branch の最新 SHA を取得 (lock 取得後) ---
BASE_SHA=$(git rev-parse "refs/heads/${BASE}")
echo "[auto-merge] base=${BASE} sha=${BASE_SHA}" >&2

# --- detached worktree を /tmp に作成 ---
MERGE_DIR="/tmp/boid-merge-$$"
echo "[auto-merge] creating detached worktree at ${MERGE_DIR}" >&2
if ! git worktree add --detach "${MERGE_DIR}" "${BASE_SHA}" >&2; then
    echo "[auto-merge] ERROR: git worktree add failed" >&2
    exit 1
fi

cleanup_worktree() {
    cd / 2>/dev/null || true
    git worktree remove --force "${MERGE_DIR}" >/dev/null 2>&1 || true
}

# --- detached worktree 内で merge を試みる ---
MERGE_EXIT=0
(
    cd "${MERGE_DIR}"
    git merge --no-ff "${TASK_BRANCH}" \
        -m "Merge ${TASK_BRANCH} into ${BASE}"
) >&2 || MERGE_EXIT=$?

if [ "${MERGE_EXIT}" -ne 0 ]; then
    echo "[auto-merge] merge failed (exit=${MERGE_EXIT}): late_conflict" >&2
    cleanup_worktree
    export BASE TASK_BRANCH
    python3 - <<'PYEOF'
import os, yaml

patch = {
    'payload_patch': {
        'artifact': {
            'auto-merge': {
                'merged': False,
                'error': 'late_conflict',
                'base_branch': os.environ['BASE'],
                'task_branch': os.environ['TASK_BRANCH'],
            },
        },
    },
}
print(yaml.dump(patch, default_flow_style=False, allow_unicode=True))
PYEOF
    exit 0
fi

# --- merge commit SHA を取得 (detached HEAD) ---
MERGE_SHA=$(git -C "${MERGE_DIR}" rev-parse HEAD)
echo "[auto-merge] merge commit: ${MERGE_SHA}" >&2

# --- worktree を掃除 ---
cleanup_worktree

# --- base branch ref を atomic に更新 ---
# update-ref は「ブランチが別 worktree でチェックアウト済み」でも成功する。
if ! git update-ref "refs/heads/${BASE}" "${MERGE_SHA}" "${BASE_SHA}"; then
    echo "[auto-merge] ERROR: git update-ref failed (base may have moved)" >&2
    exit 1
fi

echo "[auto-merge] updated refs/heads/${BASE} -> ${MERGE_SHA}" >&2

# --- artifact 出力 ---
export BASE TASK_BRANCH MERGE_SHA
python3 - <<'PYEOF'
import os, yaml

patch = {
    'payload_patch': {
        'artifact': {
            'auto-merge': {
                'merged': True,
                'base_branch': os.environ['BASE'],
                'merge_commit': os.environ['MERGE_SHA'],
                'task_branch': os.environ['TASK_BRANCH'],
            },
        },
    },
}
print(yaml.dump(patch, default_flow_style=False, allow_unicode=True))
PYEOF
