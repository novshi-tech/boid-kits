# github-auto-merge

完了タスクの PR を自動マージし、コンフリクト時はタスクを reworking に戻す kit。

## Scripts

### auto-merge

- **トリガー**: `task_done`（behavior: dev）
- **役割**: 完了タスクのブランチに紐づく PR を自動マージする
- マージ前に PR の `mergeable` ステータスをポーリングし、UNKNOWN を解消する
- `mergeable == CONFLICTING` の場合:
  - `boid task update` で `artifact.pr` に `merged=false, error="conflict"` を記録
  - `verification.findings` にコンフリクト解消手順を `open` ステータスで書き込む
  - `boid task reopen` でタスクを reworking に戻す
- `mergeable == MERGEABLE` の場合:
  - `gh pr merge --merge --delete-branch` で PR をマージ
  - merge 成功/失敗を `artifact.pr` に記録
