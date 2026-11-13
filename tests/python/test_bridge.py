"""Tests for python/cellbook_bridge.py (protocol v1).

Run with: uv run pytest
Requires jupyter_client + ipykernel in the test environment (see pyproject.toml).
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "python" / "cellbook_bridge.py"


class BridgeProc:
    def __init__(self, *args: str, python: str = sys.executable) -> None:
        self.proc = subprocess.Popen(
            [python, "-u", str(BRIDGE), *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.messages: queue.Queue = queue.Queue()
        self.events: list = []
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.messages.put(json.loads(line))
        self.messages.put(None)

    def _drain_stderr(self) -> None:
        assert self.proc.stderr is not None
        for _ in self.proc.stderr:
            pass

    def read(self, timeout: float = 60.0):
        return self.messages.get(timeout=timeout)

    def send_raw(self, data: bytes) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def request(self, method: str, params=None, timeout: float = 120.0):
        self.next_id += 1
        rid = self.next_id
        self.send_raw((json.dumps({"id": rid, "method": method, "params": params or {}}) + "\n").encode())
        deadline = time.time() + timeout
        while True:
            msg = self.read(max(0.1, deadline - time.time()))
            if msg is None:
                raise RuntimeError("bridge exited")
            if msg.get("id") == rid:
                return msg
            self.events.append(msg)

    def close(self) -> int:
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()
        try:
            return self.proc.wait(20)
        finally:
            if self.proc.poll() is None:
                self.proc.kill()


@pytest.fixture
def bridge():
    b = BridgeProc("--protocol", "1")
    hello = b.read()
    assert hello["event"] == "hello"
    yield b
    b.close()


@pytest.fixture
def kernel(bridge, tmp_path):
    res = bridge.request("start_kernel", {"kernel_name": "python3", "cwd": str(tmp_path)})
    assert "result" in res, res
    return bridge


def test_hello_handshake():
    b = BridgeProc("--protocol", "1")
    hello = b.read()
    assert hello["event"] == "hello"
    params = hello["params"]
    assert params["protocol"] == 1
    assert params["bridge_version"]
    assert params["jupyter_client"]
    assert b.close() == 0


def test_protocol_mismatch():
    b = BridgeProc("--protocol", "99")
    msg = b.read()
    assert msg["event"] == "fatal"
    assert msg["params"]["code"] == "protocol_mismatch"
    assert b.close() == 4


def test_missing_dependency(tmp_path):
    # An isolated interpreter without site-packages cannot import jupyter_client.
    env_python = sys.executable
    proc = subprocess.run(
        [env_python, "-I", "-S", "-u", str(BRIDGE), "--protocol", "1"],
        input=b"",
        capture_output=True,
        timeout=60,
    )
    lines = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert lines and lines[0]["event"] == "fatal"
    assert lines[0]["params"]["code"] == "missing_dependency"
    assert "pip install" in lines[0]["params"]["fix"]
    assert proc.returncode == 3


def test_check_mode():
    proc = subprocess.run([sys.executable, str(BRIDGE), "--check"], capture_output=True, timeout=60)
    report = json.loads(proc.stdout.splitlines()[-1])
    assert report["jupyter_client"]
    assert report["protocol"] == 1
    assert any(s["name"] == "python3" for s in report["specs"])


def test_list_kernelspecs(bridge):
    res = bridge.request("list_kernelspecs")
    names = [s["name"] for s in res["result"]["specs"]]
    assert "python3" in names


def test_invalid_requests(bridge):
    bridge.send_raw(b"this is not json\n")
    res = bridge.request("no_such_method")
    assert res["error"]["code"] == "invalid_request"
    bridge.send_raw(b'{"id": 99}\n')
    msg = bridge.read()
    while msg.get("id") != 99:
        msg = bridge.read()
    assert msg["error"]["code"] == "invalid_request"
    assert bridge.request("ping")["result"]["alive"] is True


def test_no_such_kernel(bridge):
    res = bridge.request("start_kernel", {"kernel_name": "definitely-not-a-kernel"})
    assert res["error"]["code"] == "no_such_kernel"


def test_execute_ordering_and_outputs(kernel):
    kernel.events.clear()
    res = kernel.request("execute", {"code": "print('hi')\n40 + 2", "cell_id": "c1"})
    result = res["result"]
    assert result["status"] == "ok"
    assert result["execution_count"] == 1
    iopub = [e["params"] for e in kernel.events if e.get("event") == "iopub"]
    types = [m["msg_type"] for m in iopub]
    # all output for the request arrives before the reply
    assert "stream" in types and "execute_result" in types
    assert all(m["cell_id"] == "c1" for m in iopub)
    stream = next(m for m in iopub if m["msg_type"] == "stream")
    assert stream["content"]["text"] == "hi\n"
    result_msg = next(m for m in iopub if m["msg_type"] == "execute_result")
    assert result_msg["content"]["data"]["text/plain"] == "42"


def test_execute_error(kernel):
    kernel.events.clear()
    res = kernel.request("execute", {"code": "1/0", "cell_id": "c2"})
    assert res["result"]["status"] == "error"
    assert res["result"]["ename"] == "ZeroDivisionError"
    errs = [e["params"] for e in kernel.events if e.get("event") == "iopub" and e["params"]["msg_type"] == "error"]
    assert errs and errs[0]["content"]["ename"] == "ZeroDivisionError"


def test_cwd(kernel, tmp_path):
    kernel.events.clear()
    kernel.request("execute", {"code": "import os; print(os.getcwd())", "cell_id": "c"})
    out = "".join(
        e["params"]["content"]["text"]
        for e in kernel.events
        if e.get("event") == "iopub" and e["params"]["msg_type"] == "stream"
    )
    assert os.path.samefile(out.strip(), str(tmp_path))


def test_interrupt(kernel):
    done = {}

    def run():
        done["res"] = kernel.request("execute", {"code": "while True: pass", "cell_id": "loop"}, timeout=60)

    t = threading.Thread(target=run)
    t.start()
    time.sleep(1.5)
    # send the interrupt directly (request() is busy in the other thread)
    kernel.send_raw(b'{"id": 1000, "method": "interrupt", "params": {}}\n')
    t.join(30)
    assert not t.is_alive()
    assert done["res"]["result"]["status"] == "error"
    assert done["res"]["result"]["ename"] == "KeyboardInterrupt"


def test_restart_clears_namespace(kernel):
    kernel.request("execute", {"code": "x = 1", "cell_id": "a"})
    res = kernel.request("restart", {})
    assert res["result"]["language_info"]["name"] == "python"
    res = kernel.request("execute", {"code": "x", "cell_id": "b"})
    assert res["result"]["status"] == "error"
    assert res["result"]["ename"] == "NameError"


def test_kernel_death_detected(kernel):
    res = kernel.request("execute", {"code": "import os; os._exit(1)", "cell_id": "die"}, timeout=30)
    assert "error" in res and res["error"]["code"] == "kernel_dead"
    states = [e["params"]["state"] for e in kernel.events if e.get("event") == "status"]
    assert "dead" in states


def test_shutdown_exits(kernel):
    res = kernel.request("shutdown")
    assert res["result"] == {}
    assert kernel.close() == 0


def test_exit_on_stdin_close(kernel):
    assert kernel.close() == 0


def test_render_image_half_blocks(bridge):
    import base64
    import io

    from PIL import Image

    img = Image.new("RGB", (40, 20), (255, 0, 0))
    for x in range(40):
        for y in range(10, 20):
            img.putpixel((x, y), (0, 0, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    data = base64.b64encode(buf.getvalue()).decode()
    res = bridge.request("render_image", {"data": data, "cols": 20, "max_rows": 10})["result"]
    assert res["width"] == 40 and res["height"] == 20 and res["cols"] == 20
    assert len(res["rows"]) == 5  # 20 cols → 10 px tall → 5 half-block rows
    assert res["rows"][0][0] == [0xFF0000, 0xFF0000]
    assert res["rows"][-1][0] == [0x0000FF, 0x0000FF]


def test_render_image_rejects_garbage(bridge):
    res = bridge.request("render_image", {"data": "bm90IGFuIGltYWdl", "cols": 20})
    assert res["error"]["code"] == "invalid_request"
