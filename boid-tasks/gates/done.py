#!/usr/bin/env python3
"""
done gate: tasks トレイトのペイロードからサブタスクを登録する。

stdin: TaskJSON (完全なタスクデータ)
stdout: payload_patch (空 = 変更なし)

payload.tasks の各要素を boid task create に渡す。
必須フィールド: title, behavior
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

    for task in tasks:
        title = task.get("title", "")
        behavior = task.get("behavior", "")
        if not title or not behavior:
            print(
                f"warning: skipping task missing title/behavior: {task}",
                file=sys.stderr,
            )
            continue

        spec = {"title": title, "behavior": behavior}
        if task.get("description"):
            spec["description"] = task["description"]
        if task.get("project_id"):
            spec["project_id"] = task["project_id"]
        elif project_id:
            spec["project_id"] = project_id
        if task.get("payload"):
            spec["payload"] = task["payload"]

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
