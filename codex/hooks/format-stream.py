#!/usr/bin/env python3
"""Format Codex exec --json output into human-readable text."""

import json
import sys


def truncate(s, max_len=200):
    """Truncate string to max_len, appending '... (truncated)' if needed."""
    if len(s) > max_len:
        return s[:max_len] + "... (truncated)"
    return s


def clip_lines(text, max_lines=20):
    """Clip text to max_lines, appending a hint if truncated."""
    lines = text.split("\n")
    if len(lines) > max_lines:
        remaining = len(lines) - max_lines
        return "\n".join(lines[:max_lines]) + f"\n... ({remaining} more lines)"
    return text


def format_thread_started(event):
    lines = ["--- thread started ---"]
    thread_id = event.get("thread_id", "")
    if thread_id:
        lines.append(f"thread_id: {thread_id}")
    return "\n".join(lines)


def format_turn_completed(event):
    lines = ["--- turn completed ---"]
    usage = event.get("usage")
    if isinstance(usage, dict):
        for key in ("input_tokens", "cached_input_tokens", "output_tokens"):
            if key in usage:
                lines.append(f"{key}: {usage[key]}")
    return "\n".join(lines)


def format_item(event):
    item = event.get("item")
    if not isinstance(item, dict):
        return None
    itype = item.get("type", "")
    status = event.get("type", "")  # item.started / item.completed

    if itype == "agent_message":
        text = item.get("text", "")
        return f"--- assistant ---\n{text}"

    if itype == "command_execution":
        phase = "started" if status == "item.started" else "completed"
        lines = [f"--- command_execution: {phase} ---"]
        command = item.get("command", "")
        if command:
            lines.append(f"command: {truncate(str(command))}")
        exit_code = item.get("exit_code")
        if exit_code is not None:
            lines.append(f"exit_code: {exit_code}")
        output = item.get("aggregated_output", "")
        if output:
            lines.append("output:")
            lines.append(clip_lines(output))
        return "\n".join(lines)

    if itype == "file_change":
        lines = [f"--- file_change ---"]
        for key in ("path", "kind", "summary"):
            value = item.get(key)
            if value:
                lines.append(f"{key}: {truncate(str(value))}")
        return "\n".join(lines)

    if itype == "reasoning":
        text = item.get("text", "") or item.get("content", "")
        if not text:
            return None
        return f"--- reasoning ---\n{clip_lines(str(text))}"

    # Unknown item type: surface name and short payload.
    payload = truncate(json.dumps(item, ensure_ascii=False))
    return f"--- item ({itype}) ---\n{payload}"


def process_line(line):
    """Process a single line of JSONL, returning formatted text or None."""
    line = line.strip()
    if not line:
        return None

    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return f"[raw] {truncate(line)}"

    etype = event.get("type", "")

    if etype == "thread.started":
        return format_thread_started(event)
    if etype == "turn.started":
        return "--- turn started ---"
    if etype == "turn.completed":
        return format_turn_completed(event)
    if etype in ("item.started", "item.completed"):
        return format_item(event)

    # Unknown top-level event: pass through truncated.
    return f"[raw] {truncate(line)}"


def main():
    first = True
    for line in sys.stdin:
        try:
            output = process_line(line)
            if output is not None:
                if not first:
                    print()
                print(output)
                first = False
        except Exception as e:
            print(f"[error] {e}", file=sys.stderr)
            print(f"[error] {truncate(line.strip())}")


if __name__ == "__main__":
    main()
