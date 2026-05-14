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
    def test_default_type_is_executor(self):
        env = {}
        self.assertEqual(env.get("BOID_INVOKED_TYPE", "executor"), "executor")

    def test_default_name_is_empty(self):
        env = {}
        self.assertEqual(env.get("BOID_INVOKED_NAME", ""), "")

    def test_explicit_values_used(self):
        env = {"BOID_INVOKED_TYPE": "verifier", "BOID_INVOKED_NAME": "security"}
        self.assertEqual(env.get("BOID_INVOKED_TYPE", "executor"), "verifier")
        self.assertEqual(env.get("BOID_INVOKED_NAME", ""), "security")


class TestB3EnvVarHandling(unittest.TestCase):
    """B3 モード (BOID_AGENT_SESSION_ID / BOID_USER_ANSWER) のロジック検証。

    main は subprocess を起動するため直接テストしない。 B3 env vars から
    session / prompt を決定するロジックを単体で検証する。
    """

    def _resolve(self, b3_session_id, b3_user_answer, sessions, invoked_type="executor"):
        """B3 env var がある場合の session / prompt 決定ロジックを再現する。"""
        if b3_session_id:
            session_id = b3_session_id
            is_resume = True
        else:
            session_id, is_resume = run_agent.resolve_session(sessions, "executor", "")

        prompt = run_agent.select_prompt(is_resume, b3_user_answer, invoked_type)
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
        sessions = [{"type": "executor", "name": "", "id": "payload-id"}]
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
        for invoked_type, expected_prompt in [
            ("supervisor", "/boid-supervisor"),
            ("executor", "/boid-executor"),
        ]:
            with self.subTest(invoked_type=invoked_type):
                session_id, is_resume, prompt = self._resolve(
                    b3_session_id="",
                    b3_user_answer="",
                    sessions=[],
                    invoked_type=invoked_type,
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


class TestBuildClaudeArgs(unittest.TestCase):
    """`build_claude_args` の argv 構築ロジックを検証する。

    主目的は `--settings <boid-stop-settings.json>` が常に注入されることの
    回帰防止。 Stop hook がここで仕込まれないと、 agent が `boid agent stop`
    を呼び忘れた時に claude が PTY interactive のまま終わらず、 task が
    executing で stuck する。
    """

    def test_includes_settings_flag(self):
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="/boid-executor",
        )
        # --settings <path> がペアで含まれている
        self.assertIn("--settings", args)
        idx = args.index("--settings")
        self.assertLess(idx + 1, len(args), "--settings に続く path が無い")
        # boid runtime 用 stop settings を指している
        self.assertTrue(args[idx + 1].endswith("boid-stop-settings.json"), args[idx + 1])

    def test_settings_path_points_to_existing_file(self):
        # kit 内に同梱した settings JSON が実在することを確認 (deploy 漏れの回帰防止)。
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="/boid-executor",
        )
        settings_path = args[args.index("--settings") + 1]
        self.assertTrue(os.path.isfile(settings_path), f"missing settings file: {settings_path}")
        with open(settings_path) as fh:
            cfg = json.load(fh)
        # Stop hook が登録されていることを軽くスモークテスト。
        self.assertIn("hooks", cfg)
        self.assertIn("Stop", cfg["hooks"])
        stop_entries = cfg["hooks"]["Stop"]
        self.assertTrue(stop_entries, "Stop hook の entries が空")
        commands = [h.get("command", "") for entry in stop_entries for h in entry.get("hooks", [])]
        self.assertTrue(
            any("boid agent stop" in cmd for cmd in commands),
            f"Stop hook が `boid agent stop` を呼んでいない: {commands}",
        )

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

    def test_custom_settings_path_is_respected(self):
        # テスト用に別 path を渡せる (回帰防止というより API 形状確認)。
        args = run_agent.build_claude_args(
            is_resume=False,
            session_id="sess-1",
            model="",
            prompt="hi",
            stop_settings_path="/tmp/custom-settings.json",
        )
        idx = args.index("--settings")
        self.assertEqual(args[idx + 1], "/tmp/custom-settings.json")


if __name__ == "__main__":
    unittest.main()
