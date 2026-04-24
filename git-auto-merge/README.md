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

### mergeable-check (on: verifying, phase: exit)

`git merge-tree $BASE $TASK_BRANCH` で base branch との conflict を dry-run 検出する。

- conflict あり: `verification.findings` に解消手順を `status: open` で書き出し、
  reworking に戻す
- conflict なし: `verification.findings` を空にクリア

### auto-merge (on: done, phase: entry)

`flock` で排他ロックを取り、`/tmp` に detached worktree を作って `--no-ff` マージ
コミットを作成する。`git update-ref` で base branch を atomic に進める。

並列タスクが同時に done に到達してもマージは直列化されるので、マージコミットの
連鎖は保証される。

出力 artifact:

```yaml
artifact:
  auto-merge:
    merged: true            # or false
    base_branch: main
    merge_commit: <sha>     # 成功時のみ
    task_branch: boid/abcd1234
    error: late_conflict    # 失敗時のみ
```

## `github-auto-merge` との違い

| | github-auto-merge | git-auto-merge |
|---|---|---|
| 依存コマンド | `gh` | `git`, `flock`, `python3` |
| ネットワーク | 必須 (GitHub API) | 不要 |
| マージ機構 | `gh pr merge --merge` | `git merge --no-ff` + `git update-ref` |
| 共通 artifact キー | `artifact.auto-merge.merged` | 同左 |
