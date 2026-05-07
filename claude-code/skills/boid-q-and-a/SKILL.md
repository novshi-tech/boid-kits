---
name: boid-q-and-a
description: >
  Pause the current agent session and ask the user a question via boid.
  Use when plan approval, ambiguous requirements, or destructive actions require user confirmation before proceeding.
---

# boid Q&A

When user judgment is needed, pause the session, send a question via `boid task notify --ask`, and wait for the user's response. The boid runtime resumes the session automatically when the user answers.

## When to Use

- **Plan approval**: Before starting a large or risky implementation, present the plan and ask for approval (unless the request is already specific enough that there is no room for interpretation)
- **Ambiguous requirements**: When multiple approaches exist with meaningfully different trade-offs and you cannot determine the right one from context
- **Destructive actions**: Before operations that are hard to undo (data deletion, force-push, production changes, etc.)
- **Unexpected findings**: When something discovered mid-task changes the scope or approach significantly

When in doubt, err on the side of asking. One extra question costs less than building the wrong thing.

Do **not** call this for progress reports — task status is visible in the task list. Only call it when you genuinely cannot proceed without user input.

## How to Call

```bash
boid task notify "$BOID_TASK_ID" \
    --message "<brief context>" \
    --ask "<specific question>"
echo paused
exit 0
```

| Flag | Purpose |
|---|---|
| `--message` | One or two sentences explaining *what* you are doing and *why* you need input |
| `--ask` | The question itself. Markdown is rendered. List options as bullet points for easy mobile response |

`echo paused` is a required sentinel — the runner detects this exact string to transition the task to `awaiting`. Do not modify it or add text after it.

Exit immediately with `exit 0` after the notify call. Do not perform additional work.

## Writing Good Questions

Use labeled options (A/B/C) so the user can reply with a single letter on mobile:

```bash
boid task notify "$BOID_TASK_ID" \
    --message "Found two approaches for the DB migration. Both work but have different trade-offs." \
    --ask "Which approach should I use?

- **A. Online migration** — no downtime, runs a ~10 min background job, lower risk
- **B. Maintenance-window migration** — fast (< 1 min), requires ~5 min downtime
- **C. Show me a different approach**"
echo paused
exit 0
```

Guidelines:
- Keep `--message` factual and brief (what you found / what you need)
- In `--ask`, describe trade-offs concisely so the user can decide without context-switching
- Always include an escape hatch option ("C. Different approach", "C. Cancel") when relevant
- Avoid yes/no questions when the decision has real consequences — give explicit options instead

## What Happens After Pausing

After `exit 0`, boid transitions the task to `awaiting`. When the user answers (via the Web UI or `boid task answer`), boid automatically resumes the agent session with the answer injected as the next message. The agent sees it as if the user typed it — no special resume handling is needed on your end.

## Autonomous vs Interactive Mode

Check `$BOID_INTERACTIVE` before calling:

| Mode | `BOID_INTERACTIVE` | Action when stuck |
|---|---|---|
| Interactive | `1` | Call `boid task notify --ask` and pause |
| Autonomous | unset or `0` | Write the blocker to the artifact and `exit 0` — do **not** call notify |

In autonomous mode, the user monitors task state via the task list. Notify calls in autonomous mode are not actionable and should be avoided.
