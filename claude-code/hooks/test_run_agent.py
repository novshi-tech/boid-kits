#!/usr/bin/env python3
"""Tests for run-agent.py session management logic."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location(
    "run_agent",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-agent.py"),
)
run_agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run_agent)


class TestGetSessions(unittest.TestCase):
    def test_normal_payload(self):
        payload = {
            "artifact": {
                "claude_code": {
                    "sessions": [
                        {"type": "executor", "name": "", "id": "abc-123"},
                    ]
                }
            }
        }
        result = run_agent.get_sessions(payload)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "abc-123")

    def test_empty_payload(self):
        self.assertEqual(run_agent.get_sessions({}), [])

    def test_missing_artifact(self):
        self.assertEqual(run_agent.get_sessions({"instructions": {}}), [])

    def test_missing_claude_code(self):
        self.assertEqual(run_agent.get_sessions({"artifact": {}}), [])

    def test_missing_sessions(self):
        self.assertEqual(
            run_agent.get_sessions({"artifact": {"claude_code": {}}}), []
        )

    def test_none_payload(self):
        self.assertEqual(run_agent.get_sessions(None), [])


class TestResolveSession(unittest.TestCase):
    def test_hit_executor(self):
        sessions = [
            {"type": "executor", "name": "", "id": "abc-123"},
            {"type": "verifier", "name": "security", "id": "def-456"},
        ]
        session_id, is_resume = run_agent.resolve_session(sessions, "executor", "")
        self.assertEqual(session_id, "abc-123")
        self.assertTrue(is_resume)

    def test_hit_verifier_by_name(self):
        sessions = [
            {"type": "verifier", "name": "security", "id": "sec-id"},
            {"type": "verifier", "name": "performance", "id": "perf-id"},
        ]
        session_id, is_resume = run_agent.resolve_session(
            sessions, "verifier", "performance"
        )
        self.assertEqual(session_id, "perf-id")
        self.assertTrue(is_resume)

    def test_miss(self):
        sessions = [
            {"type": "executor", "name": "", "id": "abc-123"},
        ]
        session_id, is_resume = run_agent.resolve_session(
            sessions, "verifier", "security"
        )
        self.assertFalse(is_resume)
        import uuid

        uuid.UUID(session_id)

    def test_empty_sessions(self):
        session_id, is_resume = run_agent.resolve_session([], "executor", "")
        self.assertFalse(is_resume)
        import uuid

        uuid.UUID(session_id)


class TestUpdateSessions(unittest.TestCase):
    def test_add_new_to_empty(self):
        result = run_agent.update_sessions([], "executor", "", "new-id")
        self.assertEqual(result, [{"type": "executor", "name": "", "id": "new-id"}])

    def test_update_existing(self):
        sessions = [{"type": "executor", "name": "", "id": "old-id"}]
        result = run_agent.update_sessions(sessions, "executor", "", "new-id")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "new-id")

    def test_preserve_others(self):
        sessions = [
            {"type": "executor", "name": "", "id": "exec-id"},
            {"type": "verifier", "name": "security", "id": "sec-id"},
            {"type": "verifier", "name": "performance", "id": "perf-id"},
        ]
        result = run_agent.update_sessions(
            sessions, "verifier", "security", "new-sec-id"
        )
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0], {"type": "executor", "name": "", "id": "exec-id"})
        self.assertEqual(
            result[1], {"type": "verifier", "name": "security", "id": "new-sec-id"}
        )
        self.assertEqual(
            result[2], {"type": "verifier", "name": "performance", "id": "perf-id"}
        )

    def test_add_new_preserves_existing(self):
        sessions = [{"type": "executor", "name": "", "id": "exec-id"}]
        result = run_agent.update_sessions(
            sessions, "verifier", "security", "new-sec-id"
        )
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0], {"type": "executor", "name": "", "id": "exec-id"})
        self.assertEqual(
            result[1], {"type": "verifier", "name": "security", "id": "new-sec-id"}
        )


class TestBuildPayloadPatch(unittest.TestCase):
    def test_structure(self):
        sessions = [{"type": "executor", "name": "", "id": "abc-123"}]
        patch = run_agent.build_payload_patch(sessions)
        self.assertEqual(
            patch,
            {
                "payload_patch": {
                    "artifact": {
                        "claude_code": {
                            "sessions": sessions,
                        }
                    }
                }
            },
        )

    def test_multiple_sessions(self):
        sessions = [
            {"type": "executor", "name": "", "id": "abc"},
            {"type": "verifier", "name": "security", "id": "def"},
        ]
        patch = run_agent.build_payload_patch(sessions)
        self.assertEqual(
            patch["payload_patch"]["artifact"]["claude_code"]["sessions"], sessions
        )


class TestWritePayloadPatch(unittest.TestCase):
    def test_writes_valid_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sessions = [{"type": "executor", "name": "", "id": "test-id"}]
            run_agent.write_payload_patch(sessions, output_dir=tmpdir)

            output_path = os.path.join(tmpdir, "payload_patch.json")
            self.assertTrue(os.path.exists(output_path))

            with open(output_path) as f:
                data = json.load(f)

            self.assertIn("payload_patch", data)
            self.assertEqual(
                data["payload_patch"]["artifact"]["claude_code"]["sessions"],
                sessions,
            )

    def test_creates_output_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            nested = os.path.join(tmpdir, "nested", "dir")
            sessions = [{"type": "executor", "name": "", "id": "test-id"}]
            run_agent.write_payload_patch(sessions, output_dir=nested)
            self.assertTrue(os.path.exists(os.path.join(nested, "payload_patch.json")))

    def test_preserves_other_top_level_keys(self):
        # agent が書いた payload_patch の他の top-level キーを hook が上書きで失わないこと。
        # boid 本体の trait は drop されるが、 merge ロジックは agent 入力を尊重する。
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = os.path.join(tmpdir, "payload_patch.json")
            agent_written = {
                "payload_patch": {
                    "extra_metadata": {"note": "preserved by merge"},
                    "artifact": {
                        "claude_code": {
                            "sessions": [
                                {"type": "executor", "name": "", "id": "old-id"}
                            ]
                        }
                    },
                }
            }
            with open(output_path, "w") as f:
                json.dump(agent_written, f)

            sessions = [{"type": "executor", "name": "", "id": "new-id"}]
            run_agent.write_payload_patch(sessions, output_dir=tmpdir)

            with open(output_path) as f:
                data = json.load(f)

            self.assertEqual(
                data["payload_patch"]["extra_metadata"], {"note": "preserved by merge"}
            )
            self.assertEqual(
                data["payload_patch"]["artifact"]["claude_code"]["sessions"],
                sessions,
            )

    def test_preserves_other_artifact_keys(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = os.path.join(tmpdir, "payload_patch.json")
            with open(output_path, "w") as f:
                json.dump(
                    {
                        "payload_patch": {
                            "artifact": {
                                "custom_key": {"foo": "bar"},
                                "claude_code": {"sessions": []},
                            }
                        }
                    },
                    f,
                )

            run_agent.write_payload_patch(
                [{"type": "executor", "name": "", "id": "x"}], output_dir=tmpdir
            )

            with open(output_path) as f:
                data = json.load(f)

            self.assertEqual(
                data["payload_patch"]["artifact"]["custom_key"], {"foo": "bar"}
            )

    def test_corrupt_existing_falls_back_to_overwrite(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = os.path.join(tmpdir, "payload_patch.json")
            with open(output_path, "w") as f:
                f.write("\t\tnot: valid: json: ::\n")

            sessions = [{"type": "executor", "name": "", "id": "x"}]
            run_agent.write_payload_patch(sessions, output_dir=tmpdir)

            with open(output_path) as f:
                data = json.load(f)
            self.assertEqual(
                data["payload_patch"]["artifact"]["claude_code"]["sessions"],
                sessions,
            )


class TestMergeSessionsIntoPatch(unittest.TestCase):
    def test_empty_existing(self):
        sessions = [{"type": "executor", "name": "", "id": "abc"}]
        result = run_agent.merge_sessions_into_patch({}, sessions)
        self.assertEqual(
            result["payload_patch"]["artifact"]["claude_code"]["sessions"], sessions
        )

    def test_existing_tasks_preserved(self):
        existing = {"payload_patch": {"tasks": [{"title": "t"}]}}
        result = run_agent.merge_sessions_into_patch(existing, [])
        self.assertEqual(result["payload_patch"]["tasks"], [{"title": "t"}])

    def test_top_level_keys_preserved(self):
        existing = {"some_other_top_level": True, "payload_patch": {}}
        result = run_agent.merge_sessions_into_patch(existing, [])
        self.assertTrue(result["some_other_top_level"])

    def test_invalid_existing_replaced(self):
        result = run_agent.merge_sessions_into_patch("not a dict", [])
        self.assertIn("payload_patch", result)


class TestReadPayloadFromFile(unittest.TestCase):
    def test_reads_json_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(
                {
                    "artifact": {
                        "claude_code": {
                            "sessions": [
                                {"type": "executor", "name": "", "id": "file-id"}
                            ]
                        }
                    }
                },
                f,
            )
            f.flush()
            path = f.name
        try:
            payload = run_agent.read_payload_from_file(path)
            self.assertEqual(
                payload["artifact"]["claude_code"]["sessions"][0]["id"], "file-id"
            )
        finally:
            os.unlink(path)

    def test_missing_file_returns_empty(self):
        payload = run_agent.read_payload_from_file("/nonexistent/path.json")
        self.assertEqual(payload, {})

    def test_invalid_json_returns_empty(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("not json{{{")
            f.flush()
            path = f.name
        try:
            payload = run_agent.read_payload_from_file(path)
            self.assertEqual(payload, {})
        finally:
            os.unlink(path)


class TestEnvVarDefaults(unittest.TestCase):
    def test_default_behavior_is_empty(self):
        env = {}
        self.assertEqual(env.get("BOID_INVOKED_BEHAVIOR", ""), "")

    def test_default_name_is_empty(self):
        env = {}
        self.assertEqual(env.get("BOID_INVOKED_NAME", ""), "")

    def test_explicit_values_used(self):
        env = {"BOID_INVOKED_BEHAVIOR": "supervisor", "BOID_INVOKED_NAME": "security"}
        self.assertEqual(env.get("BOID_INVOKED_BEHAVIOR", ""), "supervisor")
        self.assertEqual(env.get("BOID_INVOKED_NAME", ""), "security")


class TestB3EnvVarHandling(unittest.TestCase):
    """B3 モード (BOID_AGENT_SESSION_ID / BOID_USER_ANSWER) のロジック検証。

    main は subprocess を起動するため直接テストしない。 B3 env vars から
    session / prompt を決定するロジックを単体で検証する。
    """

    def _resolve(self, b3_session_id, b3_user_answer, sessions, invoked_behavior="executor"):
        """B3 env var がある場合の session / prompt 決定ロジックを再現する。"""
        if b3_session_id:
            session_id = b3_session_id
            is_resume = True
        else:
            session_id, is_resume = run_agent.resolve_session(
                sessions, run_agent._SESSION_TYPE, ""
            )

        prompt = run_agent.select_prompt(is_resume, b3_user_answer, invoked_behavior)
        return session_id, is_resume, prompt

    def test_b3_mode_uses_env_session_id(self):
        session_id, is_resume, prompt = self._resolve(
            b3_session_id="b3-uuid-1234",
            b3_user_answer="yes, go ahead",
            sessions=[],
        )
        self.assertEqual(session_id, "b3-uuid-1234")
        self.assertTrue(is_resume)
        self.assertEqual(prompt, "yes, go ahead")

    def test_b3_mode_empty_user_answer_uses_resume_prompt(self):
        # reopen 等、 answer なし resume では state-changed prompt に落ちる。
        # /boid-sandbox を再投入すると履歴を信じて即終了する症状の対策。
        session_id, is_resume, prompt = self._resolve(
            b3_session_id="b3-uuid-1234",
            b3_user_answer="",
            sessions=[],
        )
        self.assertEqual(session_id, "b3-uuid-1234")
        self.assertTrue(is_resume)
        self.assertEqual(prompt, run_agent._RESUME_PROMPT)
        self.assertNotEqual(prompt, "/boid-sandbox")

    def test_non_b3_mode_uses_payload_session(self):
        sessions = [{"type": "execution", "name": "", "id": "payload-id"}]
        session_id, is_resume, prompt = self._resolve(
            b3_session_id="",
            b3_user_answer="",
            sessions=sessions,
        )
        self.assertEqual(session_id, "payload-id")
        self.assertTrue(is_resume)
        self.assertEqual(prompt, run_agent._RESUME_PROMPT)

    def test_non_b3_initial_run_generates_new_session(self):
        import uuid as _uuid
        for invoked_behavior, expected_prompt in [
            ("supervisor", "/boid-supervisor"),
            ("executor", "/boid-executor"),
        ]:
            with self.subTest(invoked_behavior=invoked_behavior):
                session_id, is_resume, prompt = self._resolve(
                    b3_session_id="",
                    b3_user_answer="",
                    sessions=[],
                    invoked_behavior=invoked_behavior,
                )
                self.assertFalse(is_resume)
                _uuid.UUID(session_id)  # must be a valid UUID
                self.assertEqual(prompt, expected_prompt)


class TestSelectPrompt(unittest.TestCase):
    def test_fresh_supervisor_returns_boid_supervisor(self):
        self.assertEqual(run_agent.select_prompt(False, "", "supervisor"), "/boid-supervisor")

    def test_fresh_executor_returns_boid_executor(self):
        self.assertEqual(run_agent.select_prompt(False, "", "executor"), "/boid-executor")

    def test_fresh_unknown_returns_boid_sandbox(self):
        self.assertEqual(run_agent.select_prompt(False, "", "unknown-behavior"), "/boid-sandbox")

    def test_resume_without_answer_returns_resume_prompt(self):
        prompt = run_agent.select_prompt(True, "")
        self.assertEqual(prompt, run_agent._RESUME_PROMPT)
        self.assertIn("BOID_USER_ANSWER", prompt)
        self.assertIn("instructions.yaml", prompt)

    def test_resume_with_answer_returns_answer(self):
        self.assertEqual(run_agent.select_prompt(True, "approved"), "approved")

    def test_answer_takes_precedence_when_not_resume(self):
        # is_resume=False でも user_answer があれば優先 (defensive)
        self.assertEqual(run_agent.select_prompt(False, "ans"), "ans")

    def test_resume_daemon_restart_returns_daemon_restart_prompt(self):
        prompt = run_agent.select_prompt(True, "", "executor", "daemon_restart")
        self.assertEqual(prompt, run_agent._DAEMON_RESTART_RESUME_PROMPT)
        self.assertIn("daemon", prompt)
        self.assertIn("リカバリ", prompt)

    def test_resume_other_abort_code_returns_resume_prompt(self):
        # daemon_restart 以外の abort code は通常の resume prompt
        prompt = run_agent.select_prompt(True, "", "executor", "other_code")
        self.assertEqual(prompt, run_agent._RESUME_PROMPT)

    def test_resume_empty_abort_code_returns_resume_prompt(self):
        prompt = run_agent.select_prompt(True, "", "executor", "")
        self.assertEqual(prompt, run_agent._RESUME_PROMPT)

    def test_user_answer_overrides_daemon_restart(self):
        # user_answer があれば daemon_restart abort_code より優先される
        prompt = run_agent.select_prompt(True, "go ahead", "executor", "daemon_restart")
        self.assertEqual(prompt, "go ahead")

    def test_daemon_restart_prompt_differs_from_resume_prompt(self):
        self.assertNotEqual(
            run_agent._DAEMON_RESTART_RESUME_PROMPT,
            run_agent._RESUME_PROMPT,
        )


class TestGetAbortCode(unittest.TestCase):
    """get_abort_code のユニットテスト。"""

    def test_empty_task_id_returns_empty(self):
        self.assertEqual(run_agent.get_abort_code(""), "")

    def test_none_task_id_returns_empty(self):
        # None を渡しても空文字を返す (防御的)
        self.assertEqual(run_agent.get_abort_code(None), "")

    def test_successful_call_returns_stripped_code(self):
        import unittest.mock as mock
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="daemon_restart\n")
            result = run_agent.get_abort_code("task-id-123")
        self.assertEqual(result, "daemon_restart")
        # boid CLI が正しい引数で呼ばれていること
        mock_run.assert_called_once_with(
            ["boid", "task", "get", "task-id-123", "--field", "lifecycle.abort.code"],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_empty_abort_code_field_returns_empty_string(self):
        import unittest.mock as mock
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="  \n")
            result = run_agent.get_abort_code("task-id-123")
        self.assertEqual(result, "")

    def test_nonzero_returncode_returns_empty(self):
        import unittest.mock as mock
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=1, stdout="")
            result = run_agent.get_abort_code("task-id-123")
        self.assertEqual(result, "")

    def test_oserror_returns_empty(self):
        import unittest.mock as mock
        with mock.patch("subprocess.run", side_effect=OSError("boid not found")):
            result = run_agent.get_abort_code("task-id-123")
        self.assertEqual(result, "")

    def test_timeout_returns_empty(self):
        import unittest.mock as mock
        import subprocess as _subprocess
        with mock.patch(
            "subprocess.run",
            side_effect=_subprocess.TimeoutExpired(cmd="boid", timeout=5),
        ):
            result = run_agent.get_abort_code("task-id-123")
        self.assertEqual(result, "")


class TestBuildClaudeArgs(unittest.TestCase):
    """`build_claude_args` の argv 構築ロジックを検証する。

    lifecycle-accountability Phase 2.a で `--settings` injection (旧 Stop
    hook 経路) は廃止されたため、 関連テストは削除済。 残る検証は resume /
    session-id / model フラグの正しい組み合わせ。
    """

    def test_includes_resume_when_is_resume(self):
        args = run_agent.build_claude_args(
            is_resume=True,
            session_id="sess-resume",
            model="",
            prompt="hello",
        )
        self.assertIn("--resume", args)
        self.assertEqual(args[args.index("--resume") + 1], "sess-resume")
        self.assertNotIn("--session-id", args)

    def test_includes_session_id_when_not_resume(self):
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-new",
            model="",
            prompt="hello",
        )
        self.assertIn("--session-id", args)
        self.assertEqual(args[args.index("--session-id") + 1], "sess-new")
        self.assertNotIn("--resume", args)

    def test_includes_model_when_set(self):
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="claude-opus-4-7",
            prompt="hello",
        )
        self.assertIn("--model", args)
        self.assertEqual(args[args.index("--model") + 1], "claude-opus-4-7")

    def test_omits_model_when_empty(self):
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="hello",
        )
        self.assertNotIn("--model", args)

    def test_prompt_is_last_positional(self):
        # 既存挙動と整合: prompt は argv 末尾の positional。
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="/boid-executor",
        )
        self.assertEqual(args[-1], "/boid-executor")

    def test_does_not_inject_settings_flag(self):
        # lifecycle-accountability Phase 2.a: Stop hook は廃止されたので
        # `--settings` フラグは注入されない (回帰防止)。
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="/boid-executor",
        )
        self.assertNotIn("--settings", args)

    def test_disables_webfetch(self):
        # WebFetch はサンドボックス egress allowlist で必ず 403 になるため
        # ツールごと無効化する (boid: docs/plans/sandbox-web-access.md)。
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="/boid-executor",
        )
        self.assertIn("--disallowedTools", args)
        self.assertEqual(args[args.index("--disallowedTools") + 1], "WebFetch")


if __name__ == "__main__":
    unittest.main()
