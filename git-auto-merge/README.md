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

`flock` で排他ロックを取り、**BASE branch が checked out されている worktree
で直接** `git merge --no-ff` を実行する。HEAD / index / working tree が一括で
前進するので、`update-ref` で別 worktree のブランチ ref だけ動かす旧設計が
原因の「同名ブランチを開いている worktree が古いまま取り残される desync」は
発生しない。

並列タスクが同時に done に到達してもマージは直列化されるので、マージコミットの
連鎖は保証される。

事前条件を満たさない場合は merge を行わず fail-fast し、`artifact.error` に
理由を載せて reworking に戻す:

| `error` | 条件 |
|---------|------|
| `base_not_checked_out` | `BASE` (= `BOID_BASE_BRANCH` or プライマリ worktree のブランチ) がどの worktree にも checkout されていない |
| `primary_busy` | 対象 worktree に未コミット変更がある / merge / rebase / cherry-pick / revert / `git am` のいずれかが進行中 |
| `late_conflict` | 実マージで衝突した（`mergeable-check` の dry-run をすり抜けた稀ケース） |

出力 artifact:

```yaml
artifact:
  auto-merge:
    merged: true            # or false
    base_branch: main
    merge_commit: <sha>     # 成功時のみ
    task_branch: boid/abcd1234
    error: base_not_checked_out | primary_busy | late_conflict   # 失敗時のみ
```

## `github-auto-merge` との違い

| | github-auto-merge | git-auto-merge |
|---|---|---|
| 依存コマンド | `gh` | `git`, `flock`, `python3` |
| ネットワーク | 必須 (GitHub API) | 不要 |
| マージ機構 | `gh pr merge --merge` | `git merge --no-ff` + `git update-ref` |
| 共通 artifact キー | `artifact.auto-merge.merged` | 同左 |
