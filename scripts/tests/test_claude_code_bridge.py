import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "claude_code_bridge.py"
SPEC = importlib.util.spec_from_file_location("claude_code_bridge", MODULE_PATH)
assert SPEC and SPEC.loader
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)


class ClaudeCodeBridgeTests(unittest.TestCase):
    def test_listen_url_rejects_remote_hosts_and_paths(self):
        self.assertEqual(
            bridge.parse_listen_url("http://127.0.0.1:4510"),
            ("127.0.0.1", 4510, "http://127.0.0.1:4510"),
        )
        with self.assertRaises(ValueError):
            bridge.parse_listen_url("http://example.com:4510")
        with self.assertRaises(ValueError):
            bridge.parse_listen_url("http://127.0.0.1:4510/public")

    def test_workspace_must_be_a_real_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(bridge.validated_workspace(directory), str(Path(directory).resolve()))
        with self.assertRaises(ValueError):
            bridge.validated_workspace("")

    def test_command_uses_permission_tool_and_does_not_inherit_allow_rules(self):
        command = bridge.build_claude_command(
            "/usr/local/bin/claude",
            "Be concise.",
            "/tmp/mcp.json",
            "session-123",
        )
        self.assertIn(bridge.PERMISSION_TOOL_NAME, command)
        self.assertIn("--strict-mcp-config", command)
        setting_index = command.index("--setting-sources")
        self.assertEqual(command[setting_index + 1], "")
        self.assertEqual(command[-2:], ["--resume", "session-123"])
        self.assertNotIn("Fix the test", command)

    def test_stream_parser_emits_only_visible_text_and_final_result(self):
        parser = bridge.ClaudeStreamParser()
        init_events = parser.parse(json.dumps({"type": "system", "session_id": "abc"}))
        delta_events = parser.parse(
            json.dumps(
                {
                    "type": "stream_event",
                    "event": {
                        "type": "content_block_delta",
                        "delta": {"type": "text_delta", "text": "Hello"},
                    },
                }
            )
        )
        hidden_events = parser.parse(
            json.dumps(
                {
                    "type": "stream_event",
                    "event": {
                        "type": "content_block_delta",
                        "delta": {"type": "thinking_delta", "thinking": "secret"},
                    },
                }
            )
        )
        result_events = parser.parse(
            json.dumps({"type": "result", "result": "Hello world", "is_error": False})
        )

        self.assertEqual(init_events, [{"type": "session", "session_id": "abc"}])
        self.assertEqual(delta_events, [{"type": "delta", "text": "Hello"}])
        self.assertEqual(hidden_events, [])
        self.assertEqual(result_events, [{"type": "result", "text": "Hello world"}])

    def test_turn_permission_waits_for_and_returns_user_decision(self):
        turn = bridge.TurnState("turn", "token")
        decision = {}

        def request_permission():
            decision.update(turn.request_permission("Bash", {"command": "swift test"}))

        worker = threading.Thread(target=request_permission)
        worker.start()
        event = turn.events.get(timeout=1)
        self.assertEqual(event["type"], "approval")
        self.assertEqual(event["tool_name"], "Bash")
        self.assertTrue(turn.resolve_approval(event["approval_id"], True))
        worker.join(timeout=1)

        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(decision["updatedInput"], {"command": "swift test"})

    def test_permission_mcp_advertises_the_approval_tool(self):
        requests = "\n".join(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"},
                    }
                ),
                json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
                "",
            ]
        )
        process = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "permission-mcp",
                "--bridge",
                "http://127.0.0.1:4510",
                "--turn-id",
                "turn",
                "--token",
                "token",
            ],
            input=requests,
            text=True,
            capture_output=True,
            check=True,
        )
        responses = [json.loads(line) for line in process.stdout.splitlines()]

        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(responses[1]["result"]["tools"][0]["name"], "approval_prompt")


if __name__ == "__main__":
    unittest.main()
