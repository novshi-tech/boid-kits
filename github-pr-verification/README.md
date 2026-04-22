# github-pr-verification kit

GitHub PR の CI 検証を自動化する boid kit。`pr-verify` gate が executing / reworking ステートで発火し、worktree のコミットを push して GitHub Actions の結果を verification findings として返す。

## 動作概要

1. worktree ディレクトリ（`${BOID_WORKTREE_ROOT}/<project_id>/<task_short>`）の存在を確認
2. builtin `git push` でブランチを origin に push
3. GitHub PR を作成（既存 PR があればスキップ）
4. GitHub Actions の完了を待機し、結果を `verification` として payload に出力

## セキュリティ上の注意: `host_commands` で `git` を登録してはならない

**`host_commands` に `git` を別名で登録することは禁則。**

boid には builtin `git` (shim 経由で broker の policy validation に到達する) が実装されており、以下の検証を実施している:

- subcommand ホワイトリスト
- remote 名ホワイトリスト
- force push 禁止 (`--force` / `--delete`)
- グローバルオプション拒否 (`-C`, `-c`, `--git-dir` 等)
- role ベースの動的ポリシー（`internal/orchestrator/builtin_policy.go` 参照）

`host_commands` で別名の git（例: `git-cmd: path: /usr/bin/git`）を登録すると、これらの検証を**完全に迂回**できてしまう。特に glob allow list (`-C * push*` / `-C * remote*`) では以下の攻撃が通ってしまう:

- `git remote set-url origin <攻撃者URL>` による資格情報・成果物の流出
- `git push --force` / `git push --delete` によるリモートブランチの破壊
- `-C` による worktree 外の任意リポジトリの操作

### 正しい書き方

gate / hook から git を使う場合は**必ず builtin `git` を使う**。

worktree 外のパスに対して git コマンドを実行したい場合は、subshell 内で `cd` してから実行する:

```bash
# OK: subshell 内で cd → builtin git を使用（$() は subshell なので外部の cwd に影響しない）
RESULT=$(cd "${WORKTREE_PATH}" && git rev-parse HEAD 2>/dev/null || echo "?")

# NG: host_commands で登録した git-cmd は validation を迂回する
RESULT=$(git-cmd -C "${WORKTREE_PATH}" rev-parse HEAD)
```

`push` は `RoleGate` のポリシーで許可されている。`rev-parse` / `status` は `localGitSubcommands` に含まれており shim を素通りして `/usr/bin/git` が実行される。詳細は `internal/orchestrator/builtin_policy.go` および `internal/sandbox/git_shim.go` を参照。

## rework サイクルでの無 commit abort

rework サイクル（`reworking` ステート）で agent が新しいコミットを作らずに終了した場合、`pr-verify` gate は `severity=fatal` の open finding を出力する。

```yaml
findings:
  - status: open
    severity: fatal
    message: |
      Agent made no new commits since the last rework cycle.
      The rework must produce at least one new commit with changes. Task will be aborted.
```

StateMachine は `severity=fatal` の open finding を検出すると即座に `aborted` に遷移する（reworking ループを継続しない）。

**ルール**: agent は rework 指示に対して必ず 1 commit 以上作る必要がある。

**復帰方法**: abort されたタスクは `boid task gate replay <task> <gate>` で再実行できる（`gate-replay-core` / `gate-replay-tui` 実装後）。

## 環境変数

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `BOID_WORKTREE_ROOT` | worktree のルートディレクトリ | `${HOME}/.local/share/boid/worktrees` |
| `BOID_PR_VERIFY_RUN_DETECT_RETRY` | push 後の Actions run 検出リトライ回数（1 回 = 10 秒） | `12`（2 分） |
| `BOID_PR_VERIFY_TIMEOUT` | CI 完了待機の最大ループ回数（1 回 = 10 秒） | `180`（30 分） |
