#!/usr/bin/env bash
# git-auto-merge 共通関数。
#
# mergeable-check / auto-merge の両 hook から source される。
# 単独実行向けではないため shebang はあっても exec はしない。

# detect_base_branch <task_branch>
#
# stdout に base branch 名を出力する。
#
# ルール:
#   1. BOID_BASE_BRANCH env が空でない値で設定されていればそれを使う。
#   2. 未設定の場合、git worktree list --porcelain のプライマリ worktree
#      (最初のエントリ) の branch refs/heads/<name> を採用する。
#      ただし task 自身の branch (引数) と一致する場合はスキップして
#      次のエントリを見る。
#   3. 検出できない場合は stderr にエラーを出し、exit 1。
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

    # 各 worktree エントリは空行区切り。各エントリ内に "branch refs/heads/<name>"
    # 行があればその <name> を候補にする。task_branch と一致するものはスキップ。
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
