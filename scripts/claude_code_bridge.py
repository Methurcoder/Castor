#!/usr/bin/env python3
"""Loopback-only bridge between Castor and Claude Code CLI.

The macOS app remains sandboxed. This helper is started explicitly by the user,
runs Claude Code in the selected workspace, streams only user-facing text back
to Castor, and relays unresolved tool permissions to the app through a
small MCP permission-prompt server.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


MAX_REQUEST_BYTES = 1_048_576
PERMISSION_TOOL_NAME = "mcp__castor_permissions__approval_prompt"


def compact_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def is_loopback_host(host: str | None) -> bool:
    return (host or "").lower() in {"127.0.0.1", "localhost", "::1"}


def parse_listen_url(value: str) -> tuple[str, int, str]:
    parsed = urlparse(value)
    if parsed.scheme != "http" or not is_loopback_host(parsed.hostname) or parsed.path not in {"", "/"}:
        raise ValueError("--listen must be an http:// loopback URL without a path")
    if parsed.port is None:
        raise ValueError("--listen must include a port")
    return parsed.hostname or "127.0.0.1", parsed.port, f"http://{parsed.hostname}:{parsed.port}"


def validated_workspace(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Choose a workspace folder in Castor Settings first.")
    workspace = os.path.realpath(os.path.expanduser(value.strip()))
    if not os.path.isabs(workspace) or not os.path.isdir(workspace):
        raise ValueError("The selected Claude Code workspace does not exist or is not a folder.")
    return workspace


def build_claude_command(
    claude_path: str,
    personality_instruction: str,
    mcp_config_path: str,
    session_id: str | None,
) -> list[str]:
    appended_prompt = "\n".join(
        [
            "You are speaking and acting through the Castor desktop companion.",
            personality_instruction.strip(),
            "Keep user-facing answers concise unless the user asks for detail.",
            "Never expose hidden reasoning. Use short visible progress updates instead.",
            "Every tool action not already read-only must wait for the user's Castor approval.",
        ]
    )
    command = [
        claude_path,
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--permission-mode",
        "default",
        "--permission-prompt-tool",
        PERMISSION_TOOL_NAME,
        "--strict-mcp-config",
        "--mcp-config",
        mcp_config_path,
        # Do not inherit user/project/local allow rules that could silently bypass
        # Castor's approval card. Managed enterprise policy still applies.
        "--setting-sources",
        "",
        "--append-system-prompt",
        appended_prompt,
    ]
    if session_id:
        command.extend(["--resume", session_id])
    return command


class ClaudeStreamParser:
    def __init__(self) -> None:
        self.partial_text_seen = False
        self.session_id: str | None = None

    def parse(self, line: str) -> list[dict[str, Any]]:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            return []
        if not isinstance(message, dict):
            return []

        events: list[dict[str, Any]] = []
        session_id = message.get("session_id")
        if isinstance(session_id, str) and session_id and session_id != self.session_id:
            self.session_id = session_id
            events.append({"type": "session", "session_id": session_id})

        message_type = message.get("type")
        if message_type == "stream_event":
            event = message.get("event")
            if isinstance(event, dict) and event.get("type") == "content_block_delta":
                delta = event.get("delta")
                if isinstance(delta, dict) and delta.get("type") == "text_delta":
                    text = delta.get("text")
                    if isinstance(text, str) and text:
                        self.partial_text_seen = True
                        events.append({"type": "delta", "text": text})
            return events

        if message_type == "assistant":
            claude_message = message.get("message")
            content = claude_message.get("content") if isinstance(claude_message, dict) else None
            if isinstance(content, list):
                if not self.partial_text_seen:
                    text = "".join(
                        block.get("text", "")
                        for block in content
                        if isinstance(block, dict) and block.get("type") == "text"
                    )
                    if text:
                        events.append({"type": "delta", "text": text})
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_name = block.get("name")
                        if isinstance(tool_name, str):
                            events.append(
                                {"type": "status", "message": f"Claude Code is preparing {tool_name}..."}
                            )
            return events

        if message_type == "result":
            result = message.get("result")
            if message.get("is_error") is True:
                error_text = result if isinstance(result, str) and result else "Claude Code could not complete the request."
                events.append({"type": "error", "message": error_text})
            else:
                events.append({"type": "result", "text": result if isinstance(result, str) else ""})
            return events

        return events


@dataclass
class ApprovalWaiter:
    tool_name: str
    tool_input: dict[str, Any]
    completed: threading.Event = field(default_factory=threading.Event)
    approved: bool = False


class TurnState:
    def __init__(self, turn_id: str, token: str) -> None:
        self.turn_id = turn_id
        self.token = token
        self.events: queue.Queue[dict[str, Any]] = queue.Queue()
        self.permission_serial = threading.Lock()
        self.lock = threading.Lock()
        self.approvals: dict[str, ApprovalWaiter] = {}
        self.process: subprocess.Popen[str] | None = None
        self.cancelled = threading.Event()

    def request_permission(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        # Castor shows one approval card at a time. Serialize parallel Claude
        # tool requests so a later card can never overwrite an unresolved one.
        with self.permission_serial:
            if self.cancelled.is_set():
                return {"behavior": "deny", "message": "The Castor turn was cancelled."}
            approval_id = str(uuid.uuid4())
            waiter = ApprovalWaiter(tool_name=tool_name, tool_input=tool_input)
            with self.lock:
                self.approvals[approval_id] = waiter
            self.events.put(
                {
                    "type": "approval",
                    "approval_id": approval_id,
                    "tool_name": tool_name,
                    "input": tool_input,
                }
            )
            while not waiter.completed.wait(0.25):
                if self.cancelled.is_set():
                    break
            with self.lock:
                self.approvals.pop(approval_id, None)
            if waiter.approved and not self.cancelled.is_set():
                return {"behavior": "allow", "updatedInput": tool_input}
            return {"behavior": "deny", "message": "The user declined this action in Castor."}

    def resolve_approval(self, approval_id: str, approved: bool) -> bool:
        with self.lock:
            waiter = self.approvals.get(approval_id)
            if waiter is None:
                return False
            waiter.approved = approved
            waiter.completed.set()
            return True

    def cancel(self) -> None:
        self.cancelled.set()
        with self.lock:
            waiters = list(self.approvals.values())
            process = self.process
        for waiter in waiters:
            waiter.completed.set()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()


class BridgeState:
    def __init__(self, claude_path: str, base_url: str) -> None:
        self.claude_path = claude_path
        self.base_url = base_url
        self.lock = threading.Lock()
        self.turns: dict[str, TurnState] = {}

    def add_turn(self, turn: TurnState) -> bool:
        with self.lock:
            if turn.turn_id in self.turns:
                return False
            self.turns[turn.turn_id] = turn
            return True

    def get_turn(self, turn_id: str) -> TurnState | None:
        with self.lock:
            return self.turns.get(turn_id)

    def remove_turn(self, turn_id: str) -> None:
        with self.lock:
            self.turns.pop(turn_id, None)


class ClaudeBridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CastorClaudeBridge/1.0"

    @property
    def bridge(self) -> BridgeState:
        return self.server.bridge  # type: ignore[attr-defined]

    def log_message(self, format_string: str, *args: Any) -> None:
        sys.stderr.write("[claude-bridge] " + (format_string % args) + "\n")

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = compact_json(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict[str, Any]:
        content_type = self.headers.get_content_type()
        if content_type != "application/json":
            raise ValueError("Content-Type must be application/json.")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("Invalid Content-Length.") from error
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise ValueError("Request body is empty or too large.")
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("Request body is not valid JSON.") from error
        if not isinstance(payload, dict):
            raise ValueError("Request body must be a JSON object.")
        return payload

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(
                200,
                {
                    "status": "ok",
                    "claude_path": self.bridge.claude_path,
                    "active_turns": len(self.bridge.turns),
                },
            )
            return
        self.send_json(404, {"error": "Not found."})

    def do_POST(self) -> None:
        try:
            # URLSession/curl do not add Origin. Reject browser-originated requests so
            # an arbitrary website cannot use a loopback form/fetch to trigger turns.
            if self.headers.get("Origin") is not None:
                self.send_json(403, {"error": "Browser-originated requests are not allowed."})
                return
            if self.path == "/v1/turn":
                self.handle_turn()
                return
            if self.path.startswith("/v1/turn/") and self.path.endswith("/cancel"):
                self.handle_cancel(self.path.removeprefix("/v1/turn/").removesuffix("/cancel"))
                return
            if self.path.startswith("/v1/approvals/"):
                self.handle_approval(self.path.removeprefix("/v1/approvals/"))
                return
            if self.path == "/internal/permission":
                self.handle_internal_permission()
                return
            self.send_json(404, {"error": "Not found."})
        except ValueError as error:
            self.send_json(400, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            return

    def handle_cancel(self, turn_id: str) -> None:
        turn = self.bridge.get_turn(turn_id)
        if turn is None:
            self.send_json(404, {"error": "Turn not found."})
            return
        turn.cancel()
        self.send_json(200, {"cancelled": True})

    def handle_approval(self, approval_id: str) -> None:
        payload = self.read_json()
        turn_id = payload.get("turn_id")
        approved = payload.get("approved")
        if not isinstance(turn_id, str) or not isinstance(approved, bool):
            raise ValueError("turn_id and approved are required.")
        turn = self.bridge.get_turn(turn_id)
        if turn is None or not turn.resolve_approval(approval_id, approved):
            self.send_json(404, {"error": "Approval request not found."})
            return
        self.send_json(200, {"resolved": True})

    def handle_internal_permission(self) -> None:
        payload = self.read_json()
        turn_id = payload.get("turn_id")
        tool_name = payload.get("tool_name")
        tool_input = payload.get("input")
        token = self.headers.get("X-Pomegranate-Token")
        if not isinstance(turn_id, str) or not isinstance(tool_name, str) or not isinstance(tool_input, dict):
            raise ValueError("turn_id, tool_name, and input are required.")
        turn = self.bridge.get_turn(turn_id)
        if turn is None or not token or not secrets.compare_digest(turn.token, token):
            self.send_json(403, {"error": "Invalid permission relay token."})
            return
        decision = turn.request_permission(tool_name, tool_input)
        self.send_json(200, decision)

    def handle_turn(self) -> None:
        payload = self.read_json()
        turn_id = payload.get("turn_id")
        prompt = payload.get("prompt")
        personality = payload.get("personality_instruction", "")
        session_id = payload.get("session_id")
        if not isinstance(turn_id, str) or not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("turn_id and a non-empty prompt are required.")
        try:
            uuid.UUID(turn_id)
        except ValueError as error:
            raise ValueError("turn_id must be a UUID.") from error
        if not isinstance(personality, str):
            raise ValueError("personality_instruction must be a string.")
        if session_id is not None and not isinstance(session_id, str):
            raise ValueError("session_id must be a string when provided.")
        workspace = validated_workspace(payload.get("workspace_path"))

        turn = TurnState(turn_id=turn_id, token=secrets.token_urlsafe(32))
        if not self.bridge.add_turn(turn):
            self.send_json(409, {"error": "That turn is already running."})
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def emit(event: dict[str, Any]) -> None:
            self.wfile.write(compact_json(event) + b"\n")
            self.wfile.flush()

        temp_path: str | None = None
        stderr_lines: list[str] = []
        try:
            emit({"type": "status", "message": "Starting Claude Code..."})
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as config_file:
                temp_path = config_file.name
                json.dump(
                    {
                        "mcpServers": {
                            "castor_permissions": {
                                "type": "stdio",
                                "command": sys.executable,
                                "args": [
                                    str(Path(__file__).resolve()),
                                    "permission-mcp",
                                    "--bridge",
                                    self.bridge.base_url,
                                    "--turn-id",
                                    turn_id,
                                    "--token",
                                    turn.token,
                                ],
                            }
                        }
                    },
                    config_file,
                )

            command = build_claude_command(
                self.bridge.claude_path,
                personality,
                temp_path,
                session_id,
            )
            environment = os.environ.copy()
            environment.setdefault("MCP_TIMEOUT", "30000")
            process = subprocess.Popen(
                command,
                cwd=workspace,
                env=environment,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
            with turn.lock:
                turn.process = process
            assert process.stdin is not None
            process.stdin.write(prompt.strip())
            process.stdin.close()

            parser = ClaudeStreamParser()

            def read_stdout() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    for event in parser.parse(line):
                        turn.events.put(event)
                turn.events.put({"type": "_stdout_eof"})

            def read_stderr() -> None:
                assert process.stderr is not None
                for line in process.stderr:
                    stderr_lines.append(line.rstrip())
                    if len(stderr_lines) > 30:
                        del stderr_lines[:10]

            stdout_thread = threading.Thread(target=read_stdout, daemon=True)
            stderr_thread = threading.Thread(target=read_stderr, daemon=True)
            stdout_thread.start()
            stderr_thread.start()

            stdout_eof = False
            result_seen = False
            while not stdout_eof or process.poll() is None or not turn.events.empty():
                try:
                    event = turn.events.get(timeout=0.15)
                except queue.Empty:
                    continue
                if event.get("type") == "_stdout_eof":
                    stdout_eof = True
                    continue
                if event.get("type") in {"result", "error"}:
                    result_seen = True
                emit(event)

            exit_code = process.wait()
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)
            if turn.cancelled.is_set():
                return
            if exit_code != 0 and not result_seen:
                detail = next((line for line in reversed(stderr_lines) if line.strip()), "")
                emit(
                    {
                        "type": "error",
                        "message": detail or f"Claude Code exited with status {exit_code}.",
                    }
                )
            elif not result_seen:
                emit({"type": "error", "message": "Claude Code ended without a final response."})
        except FileNotFoundError:
            emit({"type": "error", "message": "Claude Code CLI was not found. Install or configure the claude executable first."})
        except (BrokenPipeError, ConnectionResetError):
            turn.cancel()
        except Exception as error:  # Keep the local bridge alive after a single bad turn.
            try:
                emit({"type": "error", "message": f"Claude Code bridge failed: {error}"})
            except (BrokenPipeError, ConnectionResetError):
                pass
        finally:
            turn.cancel()
            self.bridge.remove_turn(turn_id)
            if temp_path:
                try:
                    os.unlink(temp_path)
                except FileNotFoundError:
                    pass


def permission_request(bridge: str, turn_id: str, token: str, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        bridge.rstrip("/") + "/internal/permission",
        data=compact_json({"turn_id": turn_id, "tool_name": tool_name, "input": tool_input}),
        headers={"Content-Type": "application/json", "X-Pomegranate-Token": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=24 * 60 * 60) as response:
            value = json.load(response)
            if isinstance(value, dict):
                return value
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        return {"behavior": "deny", "message": f"Castor approval relay failed: {error}"}
    return {"behavior": "deny", "message": "Castor returned an invalid approval response."}


def run_permission_mcp(args: argparse.Namespace) -> int:
    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
            if not isinstance(request, dict):
                continue
            request_id = request.get("id")
            method = request.get("method")
            if request_id is None:
                continue
            if method == "initialize":
                params = request.get("params")
                requested_version = params.get("protocolVersion") if isinstance(params, dict) else None
                result: dict[str, Any] = {
                    "protocolVersion": requested_version or "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "castor-permissions", "version": "1.0.0"},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {
                    "tools": [
                        {
                            "name": "approval_prompt",
                            "description": "Ask the Castor user to approve a Claude Code tool action.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "tool_name": {"type": "string"},
                                    "input": {"type": "object", "additionalProperties": True},
                                },
                                "required": ["tool_name", "input"],
                            },
                        }
                    ]
                }
            elif method == "tools/call":
                params = request.get("params")
                call_args = params.get("arguments") if isinstance(params, dict) else None
                if not isinstance(call_args, dict):
                    raise ValueError("Missing tool arguments")
                tool_name = call_args.get("tool_name")
                tool_input = call_args.get("input")
                if not isinstance(tool_name, str) or not isinstance(tool_input, dict):
                    raise ValueError("Invalid permission tool arguments")
                decision = permission_request(
                    args.bridge,
                    args.turn_id,
                    args.token,
                    tool_name,
                    tool_input,
                )
                result = {"content": [{"type": "text", "text": json.dumps(decision, separators=(",", ":"))}]}
            else:
                response = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": "Method not found"},
                }
                sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
                sys.stdout.flush()
                continue
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except Exception as error:
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": -32603, "message": str(error)},
            }
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    return 0


def run_server(args: argparse.Namespace) -> int:
    host, port, base_url = parse_listen_url(args.listen)
    claude_path = shutil.which(args.claude_path) if os.path.sep not in args.claude_path else args.claude_path
    if not claude_path or not os.path.isfile(claude_path):
        print(f"Claude Code CLI not found: {args.claude_path}", file=sys.stderr)
        return 2
    bridge = BridgeState(os.path.realpath(claude_path), base_url)
    server = ThreadingHTTPServer((host, port), ClaudeBridgeHandler)
    server.bridge = bridge  # type: ignore[attr-defined]
    print(f"Castor Claude Code bridge listening on {base_url}")
    print(f"Claude executable: {bridge.claude_path}")

    def stop_server(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop_server)
    signal.signal(signal.SIGTERM, stop_server)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        for turn in list(bridge.turns.values()):
            turn.cancel()
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")
    permission_parser = subparsers.add_parser("permission-mcp", help=argparse.SUPPRESS)
    permission_parser.add_argument("--bridge", required=True)
    permission_parser.add_argument("--turn-id", required=True)
    permission_parser.add_argument("--token", required=True)
    parser.add_argument("--listen", default="http://127.0.0.1:4510")
    parser.add_argument("--claude-path", default="claude")
    return parser


def main() -> int:
    parser = make_parser()
    args = parser.parse_args()
    if args.command == "permission-mcp":
        return run_permission_mcp(args)
    return run_server(args)


if __name__ == "__main__":
    raise SystemExit(main())
