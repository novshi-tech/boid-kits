# github-auto-merge

完了タスクの PR を自動マージし、コンフリクト時はタスクを reworking に戻す kit。

## Scripts

### auto-merge

- **トリガー**: `task_done`（behavior: dev）
- **役割**: 完了タスクのブランチに紐づく PR を自動マージする
- マージ前に PR の `mergeable` ステータスをポーリングし、UNKNOWN を解消する
- `mergeable == CONFLICTING` の場合:
  - `boid task update` で `artifact.auto-merge` に `merged=false, error="conflict"` を記録
  - `verification.findings` にコンフリクト解消手順を `open` ステータスで書き込む
  - `boid task reopen` でタスクを reworking に戻す
- `mergeable == MERGEABLE` の場合:
  - `gh pr merge --merge` で PR をマージ（ローカルブランチは boid が worktree 撤収時に掃除するため `--delete-branch` は付けない）
  - merge 成功/失敗を `artifact.auto-merge` に記録

出力 artifact:

```yaml
artifact:
  auto-merge:
    merged: true            # or false
    error: conflict         # 失敗時のみ (conflict / late_conflict)
    pr:
      number: 123
      url: https://github.com/.../pull/123
      branch: boid/abcd1234
```

`merged` キーは `git-auto-merge` kit と共通であり、下流タスクは
`depends_on_payload: "artifact.auto-merge.merged"` で kit を区別せず待機できる。
