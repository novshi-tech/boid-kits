#!/usr/bin/env python3
"""Claude Code agent runner.

Launches an interactive `claude` session (PTY-backed) for every hook invocation.
boid daemon takes care of terminating the session: when the agent calls
`boid task notify --ask` or `boid job done`, the daemon SIGTERMs the runtime.
The bash EXIT trap then fires `boid job done` and CompleteJob's idempotency
guard absorbs the second call.

We persist the claude --resume session id to payload_patch.json BEFORE starting
claude so that even an abnormal termination (SIGKILL, OOM) leaves a usable
session id for the next hook to resume from.
"""

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

# System prompt addendum reminding the agent how to pause for user input.
# Unlike the previous non-interactive flow, the agent no longer needs to emit a
# "paused" sentinel — boid daemon SIGTERMs this runtime as soon as
# `boid task notify --ask` succeeds, so just calling notify is enough.
_PAUSE_SYSTEM_PROMPT = (
    "ユーザに質問や確認が必要になった場合は、 Bash で "
    "`boid task notify \"$BOID_TASK_ID\" --message \"<コンテキスト>\" --ask \"<質問>\"` "
    "を実行せよ。 boid daemon が自動的にこのセッションを終了し、 ユーザの回答が"
    "得られた時点で新しいセッションとして再開する。 詳細は /boid-q-and-a skill 参照。"
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


def main():
    ensure_skills_symlinks()

    model = os.environ.get("BOID_MODEL", "")
    invoked_type = os.environ.get("BOID_INVOKED_TYPE", "executor")
    invoked_name = os.environ.get("BOID_INVOKED_NAME", "")

    # B3 env vars: set by boid daemon when re-spawning after user answer
    # (awaiting → executing) or as part of a continuing session.
    b3_session_id = os.environ.get("BOID_AGENT_SESSION_ID", "")
    b3_user_answer = os.environ.get("BOID_USER_ANSWER", "")

    payload_path = str(Path.home() / ".boid" / "context" / "payload.json")
    payload = read_payload_from_file(payload_path)

    # Determine session ID and whether this is a resume.
    if b3_session_id:
        # B3 mode: boid daemon injects session ID from previous run.
        session_id = b3_session_id
        is_resume = True
    else:
        # Payload-based session management (fallback / non-B3 flow).
        sessions = get_sessions(payload)
        session_id, is_resume = resolve_session(sessions, invoked_type, invoked_name)

    # Persist session id up-front so abnormal termination (SIGKILL, OOM) still
    # leaves a usable resume target for the next hook invocation. The EXIT trap
    # reads payload_patch.json regardless of how we exit.
    if not b3_session_id:
        sessions = get_sessions(payload)
        updated_sessions = update_sessions(sessions, invoked_type, invoked_name, session_id)
        write_payload_patch(updated_sessions)

    args = ["claude", "--permission-mode", "bypassPermissions"]
    if is_resume:
        args.extend(["--resume", session_id])
    else:
        args.extend(["--session-id", session_id])
    if model:
        args.extend(["--model", model])
    args.extend(["--append-system-prompt", _PAUSE_SYSTEM_PROMPT])

    prompt = select_prompt(is_resume, b3_user_answer)
    args.append(prompt)

    # Inherit stdio so claude drives the PTY that boid allocated for this job.
    # boid daemon SIGTERMs this process tree on `boid task notify --ask` or
    # `boid job done`; the EXIT trap added by the sandbox harness fires
    # `boid job done` after we exit, which CompleteJob de-duplicates.
    result = subprocess.run(args)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
