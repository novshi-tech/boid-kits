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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
. "${SCRIPT_DIR}/../scripts/lib.sh"

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
