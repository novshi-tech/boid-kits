# git-auto-merge

ローカル git 操作のみで完了タスクのブランチを base branch にマージする kit。
GitHub などのリモートサービスを必要としないため、オフライン環境や
self-hosted の純 git リポジトリでそのまま使える。

## ユースケース

- GitHub を使わない純ローカル / オンプレ git リポジトリでの boid 運用
- ネットワーク制約下での CI/CD パイプライン
- `github-auto-merge` との 1-for-1 置換（下流タスクは `artifact.auto-merge.merged`
  という共通キーで両 kit を区別せずマージ状態を判定できる）

## Detect

`detect.sh` の挙動:

| 条件 | 結果 |
|------|------|
| `BOID_LOCAL_MERGE` env あり | `optional`（GitHub リポジトリでも有効化） |
| `origin` remote が `github.com` を指す | skip（`github-auto-merge` 側に委ねる） |
| それ以外 | `optional` |

## 設定

### `BOID_BASE_BRANCH`

マージ先ブランチ名。未設定の場合は `git worktree list --porcelain` で
プライマリ worktree のチェックアウト中ブランチを検出して使う。

### `BOID_LOCAL_MERGE`

GitHub リポジトリで本 kit を明示的に有効化したいときにセットする
（detect.sh の分岐を参照）。

## Gates

### auto-merge (phase: exit)

executing 退場時に発火する host gate。 以下を 1 本のスクリプトで実施する:

1. `git merge-tree $BASE $TASK_BRANCH` で base branch との conflict を dry-run 検出
2. conflict あり: `artifact.auto-merge.error = merge_conflict` を出して exit 1
   （state machine 側で job_failed → aborted に遷移）
3. conflict なし: `flock` で排他ロックを取り、 BASE branch が checked out
   されている worktree で **`git merge --no-ff`** を実行し、 HEAD / index /
   working tree を一括で前進させる

並列タスクが同時に completed に到達してもマージは直列化されるので、
マージコミットの連鎖は保証される。

事前条件を満たさない場合は merge を行わず exit 1 する:

| `error` | 条件 |
|---------|------|
| `merge_conflict` | dry-run でコンフリクト検出 |
| `base_not_checked_out` | `BASE` がどの worktree にも checkout されていない |
| `primary_busy` | 対象 worktree に未コミット変更がある / merge / rebase / cherry-pick / revert / `git am` のいずれかが進行中 |
| `late_conflict` | 実マージで衝突した（dry-run をすり抜けた稀ケース） |
| `merge_tree_error` | `git merge-tree` 自体がスクリプトエラーで失敗 |

出力 artifact:

```yaml
artifact:
  auto-merge:
    merged: true            # or false
    base_branch: main
    merge_commit: <sha>     # 成功時のみ
    task_branch: boid/abcd1234
    error: merge_conflict | base_not_checked_out | primary_busy | late_conflict | merge_tree_error  # 失敗時のみ
```

## `github-auto-merge` との違い

| | github-auto-merge | git-auto-merge |
|---|---|---|
| 依存コマンド | `gh` | `git`, `flock`, `python3` |
| ネットワーク | 必須 (GitHub API) | 不要 |
| マージ機構 | `gh pr merge --merge` | `git merge --no-ff` |
| 共通 artifact キー | `artifact.auto-merge.merged` | 同左 |
