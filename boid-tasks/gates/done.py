#!/usr/bin/env python3
"""
done gate: tasks トレイトのペイロードからサブタスクを登録する。

stdin: TaskJSON (完全なタスクデータ)
stdout: payload_patch (空 = 変更なし)

payload.tasks の各要素を boid task create に渡す。
必須フィールド: title, behavior

depends_on の ref 解決:
  各タスクに ref (任意の名前) を付与し、depends_on で ref 名を指定できる。
  UUID 形式の値はそのまま渡し、それ以外は同一バッチ内の ref として解決する。
"""
import json
import re
import subprocess
import sys
import uuid

UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)


def main():
    data = json.load(sys.stdin)
    payload = data.get("payload") or {}
    tasks = payload.get("tasks") or []

    if not tasks:
        return

    project_id = data.get("project_id", "")

    # --- 1st pass: ID 事前割り当て & ref → ID マッピング構築 ---
    task_ids = []
    ref_to_id = {}
    for task in tasks:
        task_id = str(uuid.uuid4())
        task_ids.append(task_id)
        ref = task.get("ref", "")
        if ref:
            ref_to_id[ref] = task_id

    # --- 2nd pass: タスク作成 ---
    for i, task in enumerate(tasks):
        title = task.get("title", "")
        behavior = task.get("behavior", "")
        if not title or not behavior:
            print(
                f"warning: skipping task missing title/behavior: {task}",
                file=sys.stderr,
            )
            continue

        spec = {"id": task_ids[i], "title": title, "behavior": behavior}
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
            resolved = []
            for dep in task["depends_on"]:
                if UUID_PATTERN.match(dep):
                    resolved.append(dep)
                elif dep in ref_to_id:
                    resolved.append(ref_to_id[dep])
                else:
                    print(
                        f"warning: depends_on ref {dep!r} not found in batch (task {title!r})",
                        file=sys.stderr,
                    )
            spec["depends_on"] = resolved
        if task.get("depends_on_payload"):
            spec["depends_on_payload"] = task["depends_on_payload"]
        if task.get("auto_start"):
            spec["auto_start"] = task["auto_start"]

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
