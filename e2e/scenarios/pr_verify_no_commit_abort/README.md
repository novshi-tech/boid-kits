# E2E シナリオ: pr_verify_no_commit_abort

## 概要

rework サイクルで agent が新しいコミットを作らなかった場合に、`pr-verify` gate が `severity=fatal` の open finding を出力し、StateMachine が `aborted` に遷移することを確認する。

## シナリオ手順

1. **初回 executing**: agent が open finding を残す（CI 失敗を模倣）
2. **reworking サイクル**: agent が exit 0 するが新しい commit を作らない
3. **pr-verify gate**: push が up-to-date かつ `PREV_RUN_ID` が存在するため、前回 CI 結果を確認。前回 CI が成功していないので `severity=fatal` の open finding を出力
4. **StateMachine**: fatal finding を検出して `aborted` に遷移

## 期待する payload_patch.json

```json
{
  "payload_patch": {
    "verification": {
      "findings": [
        {
          "status": "open",
          "severity": "fatal",
          "message": "Agent made no new commits since the last rework cycle.\nThe rework must produce at least one new commit with changes. Task will be aborted.\nDIAGNOSTIC:\n  task_short=<task_short>\n  branch=boid/<task_short>\n  local_head=<sha>\n  prev_run_id=<run_id>\n  push_exit=0\n  push_out_first10=...|Everything up-to-date|...\n  branch=up_to_date\n  prev_run_status=completed\n  prev_conclusion=failure"
        }
      ]
    }
  }
}
```

## 検証アサーション

- `findings[0].status == "open"`
- `findings[0].severity == "fatal"`
- `findings[0].message` に `"Agent made no new commits"` を含む
- タスク最終ステータスが `aborted`
