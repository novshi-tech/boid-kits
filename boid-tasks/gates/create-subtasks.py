#!/usr/bin/env python3
"""
create-subtasks gate (entry gate on done):
tasks トレイトのペイロードからサブタスクを登録する。

done 入場時に発火し、親タスクの最終的な tasks trait を使ってサブタスクを生成する。

stdin: TaskJSON (完全なタスクデータ)
stdout: payload_patch (空 = 変更なし)

payload.tasks の各要素を boid task create に渡す。
必須フィールド: title, behavior

depends_on は ref 名をそのまま渡す（サーバー側で ref + parent_id により解決される）。
"""
import json
import subprocess
import sys


def main():
    data = json.load(sys.stdin)
    payload = data.get("payload") or {}
    tasks = payload.get("tasks") or []

    if not tasks:
        return

    project_id = data.get("project_id", "")
    parent_id = data.get("id", "")

    for task in tasks:
        title = task.get("title", "")
        behavior = task.get("behavior", "")
        if not title or not behavior:
            print(
                f"warning: skipping task missing title/behavior: {task}",
                file=sys.stderr,
            )
            continue

        spec = {"title": title, "behavior": behavior, "parent_id": parent_id}
        if task.get("ref"):
            spec["ref"] = task["ref"]
        if task.get("description"):
            spec["description"] = task["description"]
        if task.get("project_id"):
            spec["project_id"] = task["project_id"]
        elif project_id:
            spec["project_id"] = project_id
        if task.get("payload"):
            spec["payload"] = task["payload"]
        if task.get("depends_on"):
            spec["depends_on"] = task["depends_on"]
        if task.get("depends_on_payload"):
            spec["depends_on_payload"] = task["depends_on_payload"]
        if task.get("auto_start"):
            spec["auto_start"] = task["auto_start"]
        if task.get("base_branch"):
            spec["base_branch"] = task["base_branch"]

        result = subprocess.run(
            ["boid", "task", "create"],
            input=json.dumps(spec).encode(),
            capture_output=True,
        )
        if result.returncode != 0:
            print(
                f"failed to create task {title!r}: {result.stderr.decode().strip()}",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.stderr.write(result.stdout.decode())


if __name__ == "__main__":
    main()
