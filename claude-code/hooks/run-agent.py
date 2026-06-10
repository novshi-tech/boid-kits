#!/usr/bin/env python3
"""Claude Code agent runner.

Launches an interactive `claude` session (PTY-backed) for every hook
invocation. When the agent calls `boid task notify --ask`, the boid daemon
delivers SIGUSR1 to the runtime's process group. The outer / inner bash
scripts mark SIGUSR1 as SIG_IGN (`trap '' USR1`) which is inherited across
execve(2), so bash / pasta / unshare all survive untouched. claude is
launched in its own session via `start_new_session=True`, so it never sees
the group SIGUSR1. The Python signal handler installed below is therefore
the sole responder: it sends SIGTERM to just the claude process, letting
claude shut down gracefully (flush transcript / session jsonl). After
claude exits, run-agent.py exits naturally → bash sees foreground done →
EXIT trap fires `boid job done --output-file payload_patch.json` against
the still-valid broker token, completing the job through the normal path
with the agent's payload_patch (session id) intact.

We persist the claude --resume session id to payload_patch.json BEFORE
starting claude so that even an abnormal termination (SIGKILL, OOM) leaves
a usable session id for the next hook to resume from.
"""

import json
import os
import signal
import subprocess
import sys
import uuid
from pathlib import Path

# System prompt addendum reminding the agent how to pause for user input.
# Unlike the previous non-interactive flow, the agent no longer needs to emit a
# "paused" sentinel — boid daemon SIGTERMs this runtime as soon as
# `boid task notify --ask` succeeds, so just calling notify is enough.
_PAUSE_SYSTEM_PROMPT = (
    "セッションを終える前に必ず `boid task notify \"$BOID_TASK_ID\"` を呼ぶこと。"
    " 完了時は `--message \"<要約>\" --done \"<成果>\"`、 失敗時は"
    " `--message \"<要約>\" --fail \"<原因>\"`、 ユーザへの質問・判断要求時は"
    " `--message \"<コンテキスト>\" --ask \"<質問>\"` を使う。 呼ばずに応答を text"
    " のみで返すと、 claude が PTY で永遠に入力待ちになり task が hang する。"
    " notify 後は boid daemon が自動的にこのセッションを終了する。 詳細は"
    " `/boid-q-and-a` および `/boid-supervisor` / `/boid-executor` skill 参照。"
)

# Resume without a user answer (e.g. reopen with a new instruction): the prior
# skill expansion is already in history, so re-injecting it is noise. Claude
# binary's implicit "Continue from where you left off." biases the agent toward
# "no new work" when prior context shows a completed task. This prompt
# counteracts that by signalling state has changed and pointing the agent at
# the context files it should re-read.
_RESUME_PROMPT = (
    "状態が更新されました。 BOID_USER_ANSWER 環境変数 (Q&A 回答があれば設定されている) "
    "と ~/.boid/context/ 以下のファイル (task.yaml, instructions.yaml, payload.yaml) を"
    "確認し、 新しい状況に対応してください。 prior context が done に見えても、"
    " instructions.yaml の末尾要素は新しい指示の可能性があるので必ず読むこと。"
    " **セッションを終える前に `boid task notify --done` / `--fail` /"
    " `--ask` のいずれかを必ず呼ぶこと (idle 離脱は禁止)**。"
)

# daemon 再起動によってタスクが中断された場合の resume 専用プロンプト。
# 通常の reopen (Q&A 回答 / instruction 追記) とは異なり、直前の作業を
# 復元するリカバリ文脈であることを明示する。
_DAEMON_RESTART_RESUME_PROMPT = (
    "daemon が再起動したため、前回の作業が中断されました。"
    " ~/.boid/context/ 以下のファイル (task.yaml, instructions.yaml, payload.yaml) を確認し、"
    " 中断前に作業していたファイルや状態を把握してリカバリを試みてください。"
    " 不明な点は `boid task notify \"$BOID_TASK_ID\""
    " --message \"<コンテキスト>\" --ask \"<質問>\"` でユーザに確認してください。"
    " **セッションを終える前には必ず `--done` / `--fail` / `--ask` のいずれかを呼ぶこと"
    " (idle 離脱は禁止)**。"
)

_SKILL_BY_BEHAVIOR = {
    "supervisor": "/boid-supervisor",
    "executor": "/boid-executor",
}

# Session identity is keyed by a fixed phase tag (one agent session per task),
# not by behavior. Kept as "execution" for backward compatibility with session
# entries already persisted in task payloads. Skill selection is a separate
# concern, driven by BOID_INVOKED_BEHAVIOR (see select_prompt / main).
_SESSION_TYPE = "execution"


def get_abort_code(task_id):
    """Return lifecycle.abort.code for task_id, or "" on any failure."""
    if not task_id:
        return ""
    try:
        result = subprocess.run(
            ["boid", "task", "get", task_id, "--field", "lifecycle.abort.code"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""


def select_prompt(is_resume, user_answer, invoked_behavior="", abort_code=""):
    if user_answer:
        return user_answer
    if is_resume:
        if abort_code == "daemon_restart":
            return _DAEMON_RESTART_RESUME_PROMPT
        return _RESUME_PROMPT
    return _SKILL_BY_BEHAVIOR.get(invoked_behavior, "/boid-sandbox")


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


def build_claude_args(
    *,
    is_resume,
    session_id,
    model,
    prompt,
):
    """Build the argv for the `claude` subprocess.

    Factored out so tests can verify option ordering without launching claude.
    The caller appends the positional prompt last (after this returns),
    matching the existing flow.

    Note: previously this injected a `--settings` flag pointing at
    `boid-stop-settings.json` (a Stop hook that auto-fired `boid agent stop`
    when the agent forgot to call boid commands). That safety net was removed
    as part of lifecycle-accountability Phase 2.a — the new contract is that
    agents (executor / supervisor skills) explicitly call `boid task notify`
    with `done_request:` / `failure_report:` prefixes before exiting, and
    parent supervisors detect stuck children via polling.
    """
    # WebFetch はサンドボックスの egress allowlist (boid proxy) で必ず 403 に
    # なるため、ツールごと無効化してエージェントが無駄ターンを踏まないようにする。
    # web 取得は将来 boid 仲介ツールで提供予定 (boid: docs/plans/sandbox-web-access.md)。
    args = [
        "claude",
        "--permission-mode",
        "bypassPermissions",
        "--disallowedTools",
        "WebFetch",
    ]
    if is_resume:
        args.extend(["--resume", session_id])
    else:
        args.extend(["--session-id", session_id])
    if model:
        args.extend(["--model", model])
    args.extend(["--append-system-prompt", _PAUSE_SYSTEM_PROMPT])
    args.append(prompt)
    return args


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
    # BOID_INVOKED_BEHAVIOR (executor / supervisor, canonicalised by boid) selects
    # the agent skill. It replaced BOID_INVOKED_TYPE, which carried the instruction
    # phase ("execution") — never a behavior — so it always fell through to the
    # /boid-sandbox shim instead of /boid-executor or /boid-supervisor.
    invoked_behavior = os.environ.get("BOID_INVOKED_BEHAVIOR", "")
    invoked_name = os.environ.get("BOID_INVOKED_NAME", "")
    task_id = os.environ.get("BOID_TASK_ID", "")

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
        session_id, is_resume = resolve_session(sessions, _SESSION_TYPE, invoked_name)

    # Persist session id up-front so abnormal termination (SIGKILL, OOM) still
    # leaves a usable resume target for the next hook invocation. The EXIT trap
    # reads payload_patch.json regardless of how we exit.
    if not b3_session_id:
        sessions = get_sessions(payload)
        updated_sessions = update_sessions(sessions, _SESSION_TYPE, invoked_name, session_id)
        write_payload_patch(updated_sessions)

    # Fetch abort code only on resume without a user answer to distinguish
    # daemon_restart aborts from normal reopens (Q&A or new instruction).
    abort_code = ""
    if is_resume and not b3_user_answer:
        abort_code = get_abort_code(task_id)

    prompt = select_prompt(is_resume, b3_user_answer, invoked_behavior, abort_code)
    args = build_claude_args(
        is_resume=is_resume,
        session_id=session_id,
        model=model,
        prompt=prompt,
    )

    # Install the SIGUSR1 handler BEFORE launching claude so a daemon-sent
    # agent-stop signal cannot slip through during the Popen() call. The
    # handler closes over a mutable container holding the Popen — until
    # Popen returns the container is empty and the handler is a no-op (the
    # window where SIGUSR1 could fire here is microseconds at worst, but
    # the no-op is cheaper than the race). After Popen the container is
    # populated and subsequent SIGUSR1 deliveries terminate claude.
    proc_holder = {"proc": None, "stopped_by_daemon": False}

    def on_agent_stop(_signum, _frame):
        proc = proc_holder.get("proc")
        # Record that the daemon (not claude itself or the host) initiated
        # the shutdown so we can normalise the exit code below. Without
        # this flag, claude's SIGTERM-induced exit code 143 would propagate
        # up to `boid job done --exit-code 143` and the daemon would mark
        # the job (and thus the entire awaiting task) as job_failed →
        # aborted. The daemon's agent-stop is an intentional Q&A pause, not
        # a failure.
        proc_holder["stopped_by_daemon"] = True
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
        except OSError:
            # Process already gone — nothing to do.
            pass

    signal.signal(signal.SIGUSR1, on_agent_stop)
    # pasta blocks SIGUSR1 at the kernel level (sigprocmask) for its own
    # internal use, and the block is inherited by every descendant via
    # fork(2). signal.signal() above only registers a handler — the signal
    # would stay queued in pending state forever unless we also unblock it
    # here. Without this unblock, the handler never fires and the daemon's
    # agent-stop signal silently never lands.
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1})

    def on_winch(_signum, _frame):
        # Terminal resize forwarding. When a web/CLI client resizes its
        # terminal, the daemon updates the PTY winsize; the kernel then
        # delivers SIGWINCH to the PTY's foreground process group — the
        # bash / pasta / run-agent.py chain, which all share that group.
        # claude runs in its OWN session (start_new_session=True below), so
        # the group SIGWINCH never reaches it and it keeps rendering at its
        # startup width — garbling narrower (e.g. mobile) viewers, since the
        # live byte stream stays at the original column count. Forward the
        # signal to claude so it re-reads the (already-updated) PTY winsize
        # and repaints at the client's width.
        proc = proc_holder.get("proc")
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.send_signal(signal.SIGWINCH)
        except OSError:
            # Process already gone — nothing to forward to.
            pass

    signal.signal(signal.SIGWINCH, on_winch)
    # SIGWINCH's default disposition is "ignore"; register before Popen so no
    # early resize is dropped. Unblock defensively in case the inherited pasta
    # sigmask covers it (as it does for SIGUSR1).
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGWINCH})

    # Launch claude in its own session so the daemon's SIGUSR1 (delivered to
    # the runtime's process group) does not reach claude. The bash scripts
    # mark SIGUSR1 as SIG_IGN (`trap '' USR1`) which is inherited across
    # execve(2) to all intermediate processes (pasta / unshare / inner bash
    # / run-agent.py until signal.signal() above overrides), so the group
    # signal harmlessly bounces off everyone except this Python handler.
    proc = subprocess.Popen(args, start_new_session=True)
    proc_holder["proc"] = proc

    # Wait for claude to exit. wait() is interruptible: when SIGUSR1
    # arrives, Python invokes on_agent_stop (which terminates claude),
    # wait() resumes and returns once claude is reaped.
    exit_code = proc.wait()
    if proc_holder["stopped_by_daemon"]:
        # The daemon asked us to pause for Q&A; this is success from
        # boid's perspective. Exit 0 so bash's EXIT trap propagates
        # `boid job done --exit-code 0` and the task can settle into
        # awaiting cleanly.
        sys.exit(0)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
