---
name: boid-q-and-a
description: >
  Pause the current agent session and ask the user a question via boid.
  Use when plan approval, ambiguous requirements, or destructive actions require user confirmation before proceeding.
---

# boid Q&A

When user judgment is needed, send a question via `boid task notify --ask`. The boid daemon transitions the task to `awaiting`, **terminates this agent session automatically**, and spawns a fresh session with the user's answer injected once they reply.

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
```

| Flag | Purpose |
|---|---|
| `--message` | One or two sentences explaining *what* you are doing and *why* you need input |
| `--ask` | The question itself. Markdown is rendered. List options as bullet points for easy mobile response |

After the call returns successfully, **stop generating** — the boid daemon will SIGTERM this runtime shortly. No sentinel output, no explicit `exit`, and no further work is required.

## Writing Good Questions

Use labeled options (A/B/C) so the user can reply with a single letter on mobile:

```bash
boid task notify "$BOID_TASK_ID" \
    --message "Found two approaches for the DB migration. Both work but have different trade-offs." \
    --ask "Which approach should I use?

- **A. Online migration** — no downtime, runs a ~10 min background job, lower risk
- **B. Maintenance-window migration** — fast (< 1 min), requires ~5 min downtime
- **C. Show me a different approach**"
```

Guidelines:
- Keep `--message` factual and brief (what you found / what you need)
- In `--ask`, describe trade-offs concisely so the user can decide without context-switching
- Always include an escape hatch option ("C. Different approach", "C. Cancel") when relevant
- Avoid yes/no questions when the decision has real consequences — give explicit options instead

## What Happens After Pausing

After `boid task notify --ask` returns, the daemon transitions the task to `awaiting` and immediately sends SIGTERM to the agent runtime. The bash EXIT trap fires `boid job done` (absorbed idempotently), and the session ends.

When the user answers (via the Web UI or `boid task answer`), boid spawns a fresh agent session with the answer surfaced as `$BOID_USER_ANSWER` and the prior `claude --resume` session id restored, so context continuity is preserved.
