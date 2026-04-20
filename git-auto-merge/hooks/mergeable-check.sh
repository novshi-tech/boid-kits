#!/usr/bin/env bash
# mergeable-check hook (on: verifying)
#
# git merge-tree で base branch との conflict を dry-run 検出する。
# - conflict あり: verification.findings に open finding を出力 (→ reworking)
# - conflict なし: findings を空にクリア
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
    echo "[mergeable-check] ERROR: BOID_TASK_ID is not set" >&2
    exit 1
fi

TASK_BRANCH="boid/${TASK_ID:0:8}"
echo "[mergeable-check] task=${TASK_ID} branch=${TASK_BRANCH}" >&2

BASE=$(detect_base_branch "${TASK_BRANCH}")
echo "[mergeable-check] base=${BASE}" >&2

# --- git merge-tree (git 2.38+ の新モード) で conflict 検出 ---
# exit 0: conflict なし
# exit 1: conflict あり (stderr/stdout に情報)
# exit 2+: スクリプトエラー
#
# set -e をバイパスするため || で受ける。
MERGE_TREE_OUT=""
MERGE_TREE_EXIT=0
MERGE_TREE_OUT=$(git merge-tree "${BASE}" "${TASK_BRANCH}" 2>&1) || MERGE_TREE_EXIT=$?

if [ "${MERGE_TREE_EXIT}" -ge 2 ]; then
    echo "[mergeable-check] ERROR: git merge-tree failed (exit=${MERGE_TREE_EXIT})" >&2
    printf '%s\n' "${MERGE_TREE_OUT}" >&2
    exit 1
fi

if [ "${MERGE_TREE_EXIT}" -eq 1 ]; then
    echo "[mergeable-check] conflict detected with base branch ${BASE}" >&2
    export BASE
    python3 - <<'PYEOF'
import os, yaml

base = os.environ['BASE']
message = (
    f'base ブランチ ({base}) とマージコンフリクトしています。\n'
    f'worktree で以下を実行してコンフリクトを解消してください:\n'
    f'\n'
    f'  1. git merge {base}\n'
    f'  2. コンフリクトを解消\n'
    f'  3. git add <resolved_files> && git commit'
)
patch = {
    'payload_patch': {
        'verification': {
            'findings': [{
                'message': message,
                'status': 'open',
            }],
        },
    },
}
print(yaml.dump(patch, default_flow_style=False, allow_unicode=True))
PYEOF
    exit 0
fi

# --- conflict なし: findings を空にクリア ---
echo "[mergeable-check] no conflicts with base branch ${BASE}" >&2
python3 - <<'PYEOF'
import yaml

patch = {
    'payload_patch': {
        'verification': {
            'findings': [],
        },
    },
}
print(yaml.dump(patch, default_flow_style=False, allow_unicode=True))
PYEOF
