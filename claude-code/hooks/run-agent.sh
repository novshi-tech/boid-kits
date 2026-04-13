#!/bin/bash
set -e

# ~/.claude/skills/boid-sandbox が存在しない場合はシンボリックリンクを作成する
SKILLS_SRC="${HOME}/.local/share/boid/skills/boid-sandbox"
SKILLS_LINK="${HOME}/.claude/skills/boid-sandbox"
if [ ! -e "$SKILLS_LINK" ] && [ ! -L "$SKILLS_LINK" ]; then
    mkdir -p "$(dirname "$SKILLS_LINK")"
    ln -s "$SKILLS_SRC" "$SKILLS_LINK"
fi

MODEL_FLAG=""
if [ -n "${BOID_MODEL:-}" ]; then
    MODEL_FLAG="--model ${BOID_MODEL}"
fi

# Session resume: BOID_TASK_ID から決定的に UUID を生成し、
# rework 時に同一セッションを --resume で継続する。
# ~/.claude はホストから rw バインドマウントされているため、
# セッションデータとマーカーファイルの両方が永続化される。
SESSION_UUID=$(python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, '${BOID_TASK_ID}'))")
SESSION_MARKER="${HOME}/.claude/.boid-sessions/${BOID_TASK_ID}"

if [ -f "$SESSION_MARKER" ]; then
    SESSION_FLAG="--resume ${SESSION_UUID}"
else
    SESSION_FLAG="--session-id ${SESSION_UUID}"
fi

# claude 実行（終了コードを保存して後続処理に進む）
set +e
if [ "${BOID_INTERACTIVE:-0}" = "1" ]; then
    claude --dangerously-skip-permissions $SESSION_FLAG $MODEL_FLAG "/boid-sandbox"
    CLAUDE_EXIT=$?
else
    # claude を controlling terminal から切り離した非 TTY 環境で起動する
    # (stdin=/dev/null, stderr→stdout pipe, setsid で新セッション)。
    # PTY slave に直接出力すると、tmux attach 時の SIGWINCH で claude (Ink/
    # Node.js) が exit(0) してしまうため、stdout は python3 経由で整形して
    # PTY に書く構成にする。
    setsid -w claude --dangerously-skip-permissions --verbose --output-format=stream-json \
        $SESSION_FLAG $MODEL_FLAG -p "/boid-sandbox" \
        < /dev/null 2>&1 \
        | python3 "$(dirname "$0")/$(basename "$0" | sed 's/run-agent\.sh$/format-stream.py/')"
    CLAUDE_EXIT=${PIPESTATUS[0]}
fi
set -e

# セッションマーカーを永続化（次回 rework で resume するため）
mkdir -p "${HOME}/.claude/.boid-sessions"
echo "${SESSION_UUID}" > "$SESSION_MARKER"

exit $CLAUDE_EXIT
