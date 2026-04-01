#!/bin/bash
set -e

TASK_TITLE=$(boid task get "$BOID_TASK_ID" --field title 2>/dev/null || echo "")
TASK_DESC=$(boid task get "$BOID_TASK_ID" --field description 2>/dev/null || echo "")

PROMPT="$TASK_TITLE"
if [ -n "$TASK_DESC" ]; then
    PROMPT="$PROMPT

$TASK_DESC"
fi

if [ -z "$PROMPT" ]; then
    echo "ERROR: no task title or description" >&2
    exit 1
fi

exec claude --dangerously-skip-permissions -p "$PROMPT"
