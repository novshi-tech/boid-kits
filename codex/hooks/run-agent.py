#!/usr/bin/env python3
"""Codex CLI agent runner with artifact-based session management."""

import json
import os
import subprocess
import sys
from pathlib import Path


def get_sessions(payload):
    if not isinstance(payload, dict):
        return []
    artifact = payload.get("artifact")
    if not isinstance(artifact, dict):
        return []
    codex = artifact.get("codex")
    if not isinstance(codex, dict):
        return []
    sessions = codex.get("sessions")
    if not isinstance(sessions, list):
        return []
    return sessions


# Session identity is keyed by a fixed phase tag (one agent session per task),
# not by behavior. Kept as "execution" for backward compatibility with session
# entries already persisted in task payloads. Skill selection is uniform —
# every task agent bootstraps via /boid-task regardless of behavior name.
_SESSION_TYPE = "execution"


def resolve_session(sessions, invoked_type, invoked_name):
    # Codex CLI does not support pre-assigning a session ID; new IDs are
    # extracted from the JSONL stream after the run. Return None for new
    # sessions so the caller knows to capture the ID from the stream.
    for session in sessions:
        if session.get("type") == invoked_type and session.get("name") == invoked_name:
            return session["id"], True
    return None, False


def update_sessions(sessions, invoked_type, invoked_name, session_id):
    if not session_id:
        return list(sessions)
    new_entry = {"type": invoked_type, "name": invoked_name, "id": session_id}
    result = []
    found = False
    for session in sessions:
        if session.get("type") == invoked_type and session.get("name") == invoked_name:
            result.append(new_entry)
            found = True
        else:
            result.append(session)
    if not found:
        result.append(new_entry)
    return result


def build_payload_patch(sessions):
    return {
        "payload_patch": {
            "artifact": {
                "codex": {
                    "sessions": sessions,
                }
            }
        }
    }


def merge_sessions_into_patch(existing, sessions):
    # agent が書いた payload_patch.json の他のキーを保持したまま sessions だけ差し替える。
    # 上書きすると agent が書いた他の artifact 子キーや top-level エントリが失われる。
    if not isinstance(existing, dict):
        existing = {}
    patch = existing.setdefault("payload_patch", {})
    if not isinstance(patch, dict):
        patch = {}
        existing["payload_patch"] = patch
    artifact = patch.setdefault("artifact", {})
    if not isinstance(artifact, dict):
        artifact = {}
        patch["artifact"] = artifact
    codex = artifact.setdefault("codex", {})
    if not isinstance(codex, dict):
        codex = {}
        artifact["codex"] = codex
    codex["sessions"] = sessions
    return existing


def write_payload_patch(sessions, output_dir=None):
    if output_dir is None:
        output_dir = str(Path.home() / ".boid" / "output")
    os.makedirs(output_dir, exist_ok=True)
    # JSON 形式に統一: agent ファイルの round-trip で YAML 1.1 implicit type 変換
    # (on:→true: 等) が起きるのを根本的に防ぐ。JSON のキーは仕様上 string 固定。
    output_path = os.path.join(output_dir, "payload_patch.json")

    existing = {}
    if os.path.exists(output_path):
        try:
            with open(output_path) as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                existing = loaded
        except (json.JSONDecodeError, OSError):
            existing = {}

    merged = merge_sessions_into_patch(existing, sessions)
    with open(output_path, "w") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)


def read_payload_from_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, IOError):
        return {}


def read_payload_from_string(data):
    if not data or not data.strip():
        return {}
    try:
        return json.loads(data)
    except (json.JSONDecodeError, ValueError):
        return {}


def ensure_skills_symlink():
    skills_src_base = Path.home() / ".local" / "share" / "boid" / "skills"
    skills_link_base = Path.home() / ".codex" / "skills"
    for skill_name in ("boid-task", "boid-orchestrate", "boid-web"):
        link = skills_link_base / skill_name
        if not link.exists() and not link.is_symlink():
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(skills_src_base / skill_name)


def extract_session_id(event):
    """Return a session-id-like value from a JSONL event, or None."""
    if not isinstance(event, dict):
        return None
    for key in ("thread_id", "session_id", "conversation_id"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def main():
    ensure_skills_symlink()

    interactive = os.environ.get("BOID_INTERACTIVE") == "1"
    model = os.environ.get("BOID_MODEL", "")
    # Session identity uses the fixed _SESSION_TYPE; the old BOID_INVOKED_TYPE
    # (always the instruction phase "execution", never a behavior) is gone.
    # BOID_INVOKED_BEHAVIOR is unused here since codex has no per-behavior skill.
    invoked_name = os.environ.get("BOID_INVOKED_NAME", "")

    if interactive:
        payload_path = str(Path.home() / ".boid" / "context" / "payload.json")
        payload = read_payload_from_file(payload_path)
    else:
        payload = read_payload_from_string(sys.stdin.read())

    sessions = get_sessions(payload)
    session_id, is_resume = resolve_session(sessions, _SESSION_TYPE, invoked_name)

    prompt = "/boid-task"

    if interactive:
        # TUI mode. --skip-git-repo-check is not supported on `codex resume`.
        # TODO: `codex resume <id>` accepts SESSION_ID but its TUI behavior for
        # a fresh prompt via argv is limited; falling back to new session if
        # resume fails is left to the user. For now we honor is_resume only
        # when a stored session_id exists.
        if is_resume and session_id:
            args = ["codex", "resume", session_id, "--sandbox", "danger-full-access"]
        else:
            args = ["codex", "--sandbox", "danger-full-access", "--skip-git-repo-check"]
        if model:
            args.extend(["-m", model])
        args.append(prompt)
        result = subprocess.run(args)
        exit_code = result.returncode
        captured_session_id = session_id if is_resume else None
    else:
        # Non-interactive JSONL mode. Codex CLI does not accept a --sandbox
        # flag on `exec resume`; the resumed session inherits its original
        # policy, so we only pass --sandbox on new-session runs.
        if is_resume and session_id:
            args = [
                "codex", "exec", "resume", session_id,
                "--skip-git-repo-check",
            ]
        else:
            args = [
                "codex", "exec",
                "--skip-git-repo-check",
                "--sandbox", "danger-full-access",
            ]
        if model:
            args.extend(["-m", model])
        args.append("--json")
        args.append(prompt)

        script_path = Path(__file__).resolve()
        prefix = script_path.name.split("--", 1)[0] + "--" if "--" in script_path.name else ""
        format_stream = str(script_path.parent / f"{prefix}format-stream.py")

        codex_proc = subprocess.Popen(
            ["setsid", "-w"] + args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        format_proc = subprocess.Popen(
            ["python3", format_stream],
            stdin=subprocess.PIPE,
        )

        captured_session_id = session_id if is_resume else None
        try:
            for raw in codex_proc.stdout:
                if captured_session_id is None:
                    try:
                        event = json.loads(raw.decode("utf-8", errors="replace"))
                    except (json.JSONDecodeError, ValueError):
                        event = None
                    found = extract_session_id(event)
                    if found:
                        captured_session_id = found
                try:
                    format_proc.stdin.write(raw)
                    format_proc.stdin.flush()
                except BrokenPipeError:
                    break
        finally:
            try:
                format_proc.stdin.close()
            except BrokenPipeError:
                pass
            codex_proc.stdout.close()

        format_proc.wait()
        exit_code = codex_proc.wait()

        if captured_session_id is None:
            print(
                "warning: codex session_id could not be extracted from JSONL stream",
                file=sys.stderr,
            )

    updated_sessions = update_sessions(
        sessions, _SESSION_TYPE, invoked_name, captured_session_id
    )
    write_payload_patch(updated_sessions)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
