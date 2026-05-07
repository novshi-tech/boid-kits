---
name: dev-pr-flow
description: >
  Unified workflow for shipping implementation changes: run unit tests → commit → push → create/reuse PR → watch until CI passes.
  Use when shipping a change requires the full local verify → commit → push → PR → CI cycle
  (e.g. "open a PR and watch it until CI goes green", "ship this with the same flow as a dev task").
  When user confirmation is needed mid-flow, use /boid-q-and-a to pause and ask before proceeding.
---

# dev PR flow

A unified procedure for the post-implementation steps: local verify → commit → push → create/reuse PR → CI watch.

## Scope

- The implementation is complete (or the user has declared it done by invoking this skill)
- The current branch is the target for a PR (worktree or regular branch both work)
- E2E testing is left to CI; do not run `./e2e/run.sh` locally (confirm with the user if there is a specific reason to do so)

## When to Pause and Ask

Before running this flow, pause and ask (via `/boid-q-and-a`) if any of the following apply:

- The implementation touches multiple unrelated areas and you are unsure whether to split into multiple PRs
- A destructive step is about to happen (e.g., force-overwriting a remote branch that already has CI running)
- CI consistently fails and the root cause is unclear after one fix attempt — ask whether to continue or abort
- The PR title or description cannot be inferred from context

When none of the above apply, proceed autonomously through all steps.

## Steps

### 1. Run unit tests

Before committing, always run the project's unit test suite. For Go projects:

```bash
go vet ./...
go test ./...
```

`go build` does not run tests; do not use it as a substitute. Fix any failures before moving on.

### 2. Commit

Explicitly stage only the intended files. Do not use `git add -A` or `git add .` (prevents secrets or generated artifacts from being included).

```bash
git add <files>
git commit -m "<type>: <subject>"
```

Use the project's commit prefix convention (e.g., `feat:` / `fix:` / `refactor:` / `test:`).

### 3. Push

```bash
git push -u origin HEAD
```

Force-push and history rewriting are forbidden. To undo an intermediate commit, use revert.

### 4. Create or reuse a PR

```bash
PR_URL=$(gh pr list --head "$(git branch --show-current)" --json url --jq '.[0].url // ""')
```

- `$PR_URL` is empty → create a new PR with `gh pr create --title "<title>" --body "<body>"`
- not empty → reuse the existing PR (CI re-runs automatically after the new push)

PR title and body:
- title: one line describing the branch's purpose (under 70 characters)
- body: key bullet points; if running as a boid task, include `task: <task_id>` and a summary

### 5. CI watch

```bash
gh pr checks --watch --fail-fast
```

- If the repo has no CI, this exits with code 0 immediately (fine)
- On failure, inspect failed job logs with `gh run view --log-failed`, fix the root cause, then repeat steps 2–5
- After two fix attempts with the same failure, pause and ask the user whether to continue or abort (see "When to Pause and Ask" above)
- If the PR becomes unmergeable, see "Conflict recovery" below

Once CI is green, this skill's scope is complete.

## Merge is not included

In the boid task dev behavior, the `task.exit` gate (auto-merge) merges the PR after CI goes green; this skill on its own does not merge. Only run `gh pr merge` when the user explicitly asks for it.

## Differences from running as a boid task

| Aspect | boid task (dev) | this skill alone |
|--------|----------------|------------------|
| Branch | boid provides the worktree | any current branch |
| title/body source | task.yaml | conversation / user instruction |
| On CI failure | exit non-zero → boid marks it aborted | exit non-zero → simply stops |
| Post-completion merge | `task.exit` gate auto-merges | not executed |

## Conflict recovery

If the PR can no longer be merged into base, resolve it with a merge commit (not a rebase):

```bash
git fetch origin
git merge origin/main
# resolve conflicts
git add <resolved>
git commit
git push origin HEAD
```

Then re-run step 5 (CI watch). Always use merge to keep a history that does not require force-push.
