# github-auto-merge

完了タスクの PR を自動マージし、コンフリクトのある open PR に対して解消タスクを登録する kit。

## Scripts

### auto-merge

- **トリガー**: `task_done`（behavior: dev）
- **役割**: 完了タスクのブランチに紐づく PR を自動マージする
- merge 成功/失敗を `artifact.pr` に記録

### detect-conflicts

- **トリガー**: なし（cron または手動起動）
- **役割**: 全 open PR の mergeable ステータスを走査し、コンフリクトのある PR に対して解消タスクを登録する
- 並行 rebase の連鎖を防ぐため、1回の実行で作成する解消タスクは最大1つ
- **冪等性**: dedup は DB の UNIQUE 制約（`remote_id` + `datasource_id`）に委ねている。同じ PR に対する解消タスクが既に存在する場合は skip される

## cron 設定例

```cron
*/5 * * * * flock -n /tmp/boid-detect-conflicts.lock boid script run github-auto-merge/detect-conflicts --project <PROJECT_ID>
```

`flock -n` により、前回の実行が完了していない場合は新たな実行をスキップする。
