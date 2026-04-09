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


def resolve_depends_on(depends_on, created_ids):
    """depends_on 配列内の #N インデックス参照を実タスク ID に解決する。"""
    resolved = []
    for dep in depends_on:
        if isinstance(dep, str) and dep.startswith("#"):
            try:
                idx = int(dep[1:])
            except ValueError:
                print(f"warning: invalid depends_on ref: {dep}", file=sys.stderr)
                continue
            if idx < 0 or idx >= len(created_ids):
                print(
                    f"warning: depends_on ref {dep} out of range (created: {len(created_ids)})",
                    file=sys.stderr,
                )
                continue
            resolved.append(created_ids[idx])
        else:
            resolved.append(dep)
    return resolved


def main():
    data = json.load(sys.stdin)
    payload = data.get("payload") or {}
    tasks = payload.get("tasks") or []

    if not tasks:
        return

    project_id = data.get("project_id", "")
    created_ids = []

    for task in tasks:
        title = task.get("title", "")
        behavior = task.get("behavior", "")
        if not title or not behavior:
            print(
                f"warning: skipping task missing title/behavior: {task}",
                file=sys.stderr,
            )
            created_ids.append("")
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
        if task.get("depends_on"):
            spec["depends_on"] = resolve_depends_on(task["depends_on"], created_ids)
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
        stdout = result.stdout.decode()
        sys.stderr.write(stdout)
        try:
            created = json.loads(stdout.strip())
            created_ids.append(created.get("id", ""))
        except (json.JSONDecodeError, ValueError):
            created_ids.append("")


if __name__ == "__main__":
    main()
