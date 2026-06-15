#!/usr/bin/env python3
"""
MCP server smoke test.

Starts the fat JAR, completes the initialize handshake, calls tools/list,
and verifies all 8 expected tools are registered. Tests the JSON-RPC protocol
layer (Main.kt + Engine.kt) without any AWS, Terraform, or LocalStack dependency.

Exit 0 = all 8 tools present.
Exit 1 = missing tools, protocol error, or server crash.

Wire format: the MCP Kotlin SDK v0.4.x uses newline-delimited JSON (NDJSON) —
each message is a single JSON object followed by a newline character, with no
Content-Length headers. Both sides must use this format.
"""
import json
import os
import subprocess
import sys

EXPECTED_TOOLS = [
    "list_available_blueprints",
    "generate_infrastructure_package",
    "validate_infrastructure_package",
    "plan_infrastructure_package",
    "apply_infrastructure_package",
    "detect_drift",
    "destroy_infrastructure_package",
    "audit_infrastructure_package",
]

JAR = "build/libs/gentepede-mcp-all.jar"


def send_msg(proc, msg: dict) -> None:
    """Write one JSON-RPC message as a newline-terminated JSON line."""
    proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
    proc.stdin.flush()


def read_response(proc) -> dict:
    """Read one newline-terminated JSON response from the server's stdout."""
    line = proc.stdout.readline()
    if not line:
        stderr = proc.stderr.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Server closed stdout unexpectedly.\nstderr:\n{stderr}")
    return json.loads(line.decode("utf-8"))


def main() -> int:
    env = {**os.environ, "GENTEPEDE_MODE": "LOCAL"}

    print(f"Starting MCP server from {JAR} ...")
    proc = subprocess.Popen(
        ["java", "-jar", JAR],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    try:
        # ── Step 1: initialize ────────────────────────────────────────────────
        send_msg(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "ci-smoke-test", "version": "1.0"},
            },
        })

        resp = read_response(proc)
        if "error" in resp:
            print(f"FAIL: initialize returned error: {resp['error']}", file=sys.stderr)
            return 1

        info = resp.get("result", {}).get("serverInfo", {})
        print(f"  Server: {info.get('name')} {info.get('version')}")

        # ── Step 2: initialized notification (required by MCP spec) ───────────
        send_msg(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        # ── Step 3: tools/list ────────────────────────────────────────────────
        send_msg(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})

        resp = read_response(proc)
        if "error" in resp:
            print(f"FAIL: tools/list returned error: {resp['error']}", file=sys.stderr)
            return 1

        tools = [t["name"] for t in resp.get("result", {}).get("tools", [])]
        print(f"  Registered tools ({len(tools)}): {tools}")

        missing = [t for t in EXPECTED_TOOLS if t not in tools]
        if missing:
            print(f"FAIL: missing tools: {missing}", file=sys.stderr)
            return 1

        print(f"PASS: all {len(EXPECTED_TOOLS)} tools registered correctly")
        return 0

    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
