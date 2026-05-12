#!/usr/bin/env python3
"""Claude Code agent runner with C2 (claude --print + resume) based session management."""

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

# Prompt injected as system prompt addendum to instruct the agent on pausing behavior.
_PAUSE_SYSTEM_PROMPT = (
    "ユーザに質問や確認が必要になった場合は、以下の手順を踏むこと (詳細は /boid-q-and-a skill 参照): "
    "まず Bash で `boid task notify \"$BOID_TASK_ID\" --message \"<コンテキスト>\" --ask \"<質問>\"` を実行し、"
    "その後、何もせず \"paused\" とだけ出力して終了せよ。"
)

# Resume without a user answer (e.g. reopen with a new instruction): the prior
# /boid-sandbox skill expansion is already in history, so re-injecting it is
# noise. Claude binary's implicit "Continue from where you left off." biases
# the agent toward "no new work" when prior context shows a completed task.
# This prompt counteracts that by signalling state has changed and pointing
# the agent at the context files it should re-read.
_RESUME_PROMPT = (
    "状態が更新されました。 BOID_USER_ANSWER 環境変数 (Q&A 回答があれば設定されている) "
    "と ~/.boid/context/ 以下のファイル (task.yaml, instructions.yaml, payload.yaml) を"
    "確認し、 新しい状況に対応してください。"
)


def select_prompt(is_resume, user_answer):
    if user_answer:
        return user_answer
    if is_resume:
        return _RESUME_PROMPT
    return "/boid-sandbox"


def get_sessions(payload):
    if not isinstance(payload, dict):
        return []
    artifact = payload.get("artifact")
    if not isinstance(artifact, dict):
        return []
    claude_code = artifact.get("claude_code")
    if not isinstance(claude_code, dict):
        return []
    sessions = claude_code.get("sessions")
    if not isinstance(sessions, list):
        return []
    return sessions


def resolve_session(sessions, invoked_type, invoked_name):
    for session in sessions:
        if session.get("type") == invoked_type and session.get("name") == invoked_name:
            return session["id"], True
    return str(uuid.uuid4()), False


def update_sessions(sessions, invoked_type, invoked_name, session_id):
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
                "claude_code": {
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
    claude_code = artifact.setdefault("claude_code", {})
    if not isinstance(claude_code, dict):
        claude_code = {}
        artifact["claude_code"] = claude_code
    claude_code["sessions"] = sessions
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


def ensure_skills_symlinks():
    claude_skills_dir = Path.home() / ".claude" / "skills"
    claude_skills_dir.mkdir(parents=True, exist_ok=True)

    # boid-sandbox fallback: boid daemon deploys this to ~/.local/share/boid/skills/
    # when it runs; create a symlink here in case additional_bindings didn't apply.
    boid_sandbox_link = claude_skills_dir / "boid-sandbox"
    if not boid_sandbox_link.exists() and not boid_sandbox_link.is_symlink():
        boid_skills_src = Path.home() / ".local" / "share" / "boid" / "skills" / "boid-sandbox"
        boid_sandbox_link.symlink_to(boid_skills_src)

    # Kit-provided skills: auto-link every directory under <kit_root>/skills/.
    kit_root = Path(__file__).resolve().parent.parent
    kit_skills_dir = kit_root / "skills"
    if kit_skills_dir.is_dir():
        for skill_dir in sorted(kit_skills_dir.iterdir()):
            if skill_dir.is_dir():
                skill_link = claude_skills_dir / skill_dir.name
                if not skill_link.exists() and not skill_link.is_symlink():
                    skill_link.symlink_to(skill_dir)


def run_non_interactive(args, prompt, format_stream):
    """Run claude in non-interactive (print) mode.

    Streams output through format-stream.py for display and collects the
    final result event to detect the 'paused' sentinel.

    Returns (exit_code, result_event_or_None).
    """
    full_args = ["setsid", "-w"] + args + ["-p", prompt]

    claude_proc = subprocess.Popen(
        full_args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    format_proc = subprocess.Popen(
        ["python3", format_stream],
        stdin=subprocess.PIPE,
    )

    result_event = None
    for raw_line in claude_proc.stdout:
        try:
            format_proc.stdin.write(raw_line)
            format_proc.stdin.flush()
        except BrokenPipeError:
            pass
        try:
            event = json.loads(raw_line.decode("utf-8", errors="replace"))
            if event.get("type") == "result":
                result_event = event
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass

    format_proc.stdin.close()
    format_proc.wait()
    exit_code = claude_proc.wait()
    return exit_code, result_event


def main():
    ensure_skills_symlinks()

    interactive = os.environ.get("BOID_INTERACTIVE") == "1"
    model = os.environ.get("BOID_MODEL", "")
    invoked_type = os.environ.get("BOID_INVOKED_TYPE", "executor")
    invoked_name = os.environ.get("BOID_INVOKED_NAME", "")

    # B3 env vars: set by boid daemon when re-spawning after user answer (awaiting → executing).
    b3_session_id = os.environ.get("BOID_AGENT_SESSION_ID", "")
    b3_user_answer = os.environ.get("BOID_USER_ANSWER", "")

    if interactive:
        payload_path = str(Path.home() / ".boid" / "context" / "payload.json")
        payload = read_payload_from_file(payload_path)
    else:
        payload = read_payload_from_string(sys.stdin.read())

    # Determine session ID and whether this is a resume.
    if b3_session_id:
        # B3 mode: boid daemon injects session ID from previous run.
        session_id = b3_session_id
        is_resume = True
    else:
        # Payload-based session management (fallback / non-B3 flow).
        sessions = get_sessions(payload)
        session_id, is_resume = resolve_session(sessions, invoked_type, invoked_name)

    args = ["claude", "--permission-mode", "bypassPermissions"]
    if is_resume:
        args.extend(["--resume", session_id])
    args.extend(["--session-id", session_id])
    if model:
        args.extend(["--model", model])

    if interactive:
        args.append("/boid-sandbox")
        result = subprocess.run(args)
        exit_code = result.returncode
    else:
        args.extend([
            "--append-system-prompt", _PAUSE_SYSTEM_PROMPT,
            "--output-format", "stream-json",
            "--verbose",
        ])

        script_path = Path(__file__).resolve()
        prefix = script_path.name.split("--", 1)[0] + "--" if "--" in script_path.name else ""
        format_stream = str(script_path.parent / f"{prefix}format-stream.py")

        prompt = select_prompt(is_resume, b3_user_answer)

        exit_code, result_event = run_non_interactive(args, prompt, format_stream)

        if exit_code != 0:
            print(
                f"[run-agent] claude exited with code {exit_code}",
                file=sys.stderr,
            )
        elif result_event is None:
            print(
                "[run-agent] WARNING: no result event found in output",
                file=sys.stderr,
            )
        else:
            result_text = result_event.get("result", "")
            if result_text == "paused":
                # Agent self-paused via boid task notify; task transitions to awaiting.
                # Write session to payload so B3 can provide it as BOID_AGENT_SESSION_ID.
                if not b3_session_id:
                    sessions = get_sessions(payload)
                    updated = update_sessions(sessions, invoked_type, invoked_name, session_id)
                    write_payload_patch(updated)
                sys.exit(0)

    # Persist session for subsequent runs (payload-based mode only).
    if not b3_session_id:
        sessions = get_sessions(payload)
        updated_sessions = update_sessions(sessions, invoked_type, invoked_name, session_id)
        write_payload_patch(updated_sessions)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
