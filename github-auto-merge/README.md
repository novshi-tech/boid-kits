# github-auto-merge

完了タスクの PR を自動マージする kit。 GitHub 上で `gh pr merge` を実行する。

## Gates

### auto-merge (phase: exit)

executing 退場時に発火する host gate。 1 本のスクリプトで以下を実施する:

1. ブランチ `boid/<task_short>` に紐づく PR を検索
2. 既に MERGED ならそのまま成功扱い
3. PR の `mergeable` ステータスを最大 `BOID_MERGE_POLL_RETRIES` 回ポーリング
4. CONFLICTING なら exit 1 (state machine で job_failed → aborted)
5. それ以外は `gh pr merge --merge` を試行
   - 成功: `artifact.auto-merge.merged = true` を出して exit 0
   - 失敗: `artifact.auto-merge.error = late_conflict` を出して exit 1

ローカルブランチは boid が worktree 撤収時に掃除するため
`--delete-branch` は付けない。

conflict は aborted として扱い、 解消は手動 (もしくは別タスク) で行う。

出力 artifact:

```yaml
artifact:
  auto-merge:
    merged: true            # or false
    error: merge_conflict | late_conflict | no_pr   # 失敗時のみ
    pr:
      number: 123
      url: https://github.com/.../pull/123
      branch: boid/abcd1234
```

`merged` キーは `git-auto-merge` kit と共通であり、下流タスクは
`depends_on_payload: "artifact.auto-merge.merged"` で kit を区別せず待機できる。

## 環境変数

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `BOID_MERGE_POLL_RETRIES` | mergeable ステータスのポーリング試行回数 | `6` |
| `BOID_MERGE_POLL_INTERVAL` | ポーリング間隔 (秒) | `10` |
