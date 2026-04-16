#!/bin/sh
# git-auto-merge kit detection.
#
# - BOID_LOCAL_MERGE が設定されていれば常に optional (GitHub リポジトリでも使用可)
# - origin remote が github.com を指す場合は skip (github-auto-merge と競合回避)
# - それ以外は optional
if [ -n "${BOID_LOCAL_MERGE:-}" ]; then
    echo optional
    exit 0
fi
if git remote get-url origin 2>/dev/null | grep -q 'github\.com'; then
    exit 0
fi
echo optional
