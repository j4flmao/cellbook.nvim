#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["jupyter_client>=8", "ipykernel>=6"]
# ///
"""cellbook.nvim kernel bridge.

Speaks newline-delimited JSON on stdin/stdout with Neovim and drives one Jupyter
kernel through ``jupyter_client``. See specs/001-notebook-core/contracts/bridge-protocol.md.

Run directly (``python -u cellbook_bridge.py --protocol 1``) or through uv
(``uv run --with jupyter_client --with ipykernel python -u cellbook_bridge.py``).
Only the standard library and ``jupyter_client`` are required.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import threading
import traceback
from typing import Any, Dict, Optional

PROTOCOL = 1
BRIDGE_VERSION = "0.1.0"
OUTPUT_MSG_TYPES = {
    "stream",
    "execute_result",
    "display_data",
    "update_display_data",
    "error",
    "clear_output",
    "execute_input",
}
FIX_COMMAND = "python3 -m pip install jupyter_client ipykernel   (or install uv: https://docs.astral.sh/uv/)"

# ---------------------------------------------------------------------------
# Protocol output: only protocol lines may reach the real stdout. We keep a
# private duplicate of fd 1 for the protocol and point fd 1 at stderr, so that
# stray prints (from libraries or child processes) can never corrupt the stream.
# ---------------------------------------------------------------------------

_write_lock = threading.Lock()
_proto_out = None  # type: Any


def _setup_stdout() -> None:
    global _proto_out
    try:
        sys.stdout.flush()
        fd = os.dup(1)
        os.dup2(2, 1)
        _proto_out = os.fdopen(fd, "wb", buffering=0)
    except OSError:
        _proto_out = sys.stdout.buffer
    sys.stdout = sys.stderr


def _default(obj: Any) -> Any:
    if isinstance(obj, (bytes, bytearray, memoryview)):
        import base64

        return base64.b64encode(bytes(obj)).decode("ascii")
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    return str(obj)


def send(obj: Dict[str, Any]) -> None:
    data = json.dumps(obj, ensure_ascii=True, default=_default, separators=(",", ":")).encode("ascii") + b"\n"
    out = _proto_out if _proto_out is not None else sys.stdout.buffer
    with _write_lock:
        out.write(data)
        out.flush()


def log(level: str, message: str) -> None:
    sys.stderr.write("[cellbook-bridge] %s: %s\n" % (level, message))
    sys.stderr.flush()


def send_event(event: str, params: Dict[str, Any]) -> None:
    send({"event": event, "params": params})


class BridgeError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# ---------------------------------------------------------------------------
# Kernel bridge
# ---------------------------------------------------------------------------


class Bridge:
    def __init__(self) -> None:
        self.km = None  # type: Any
        self.kc = None  # type: Any
        self.loop = None  # type: Optional[asyncio.AbstractEventLoop]
        self.queue = None  # type: Optional[asyncio.Queue]
        self.routes = {}  # type: Dict[str, Optional[str]]
        self.replies = {}  # type: Dict[str, asyncio.Future]
        self.idle = {}  # type: Dict[str, asyncio.Event]
        self.tasks = []  # type: list
        self.kernel_state = "none"
        self.restarting = False
        self.dead = False
        self.stopping = False

    # -- lifecycle ---------------------------------------------------------

    async def run(self) -> int:
        self.loop = asyncio.get_running_loop()
        self.queue = asyncio.Queue()
        threading.Thread(target=self._stdin_reader, name="cellbook-stdin", daemon=True).start()
        import jupyter_client

        send_event(
            "hello",
            {
                "protocol": PROTOCOL,
                "bridge_version": BRIDGE_VERSION,
                "python": sys.executable,
                "python_version": "%d.%d.%d" % sys.version_info[:3],
                "jupyter_client": getattr(jupyter_client, "__version__", "?"),
                "pid": os.getpid(),
            },
        )
        pending = set()
        while True:
            line = await self.queue.get()
            if line is None:
                break
            req = self._parse(line)
            if req is None:
                continue
            if req.get("method") == "shutdown":
                await self._dispatch(req)
                self.stopping = True
                break
            task = asyncio.ensure_future(self._dispatch(req))
            pending.add(task)
            task.add_done_callback(pending.discard)
        await self.cleanup()
        return 0

    def _stdin_reader(self) -> None:
        stdin = sys.stdin.buffer
        loop = self.loop
        assert loop is not None and self.queue is not None
        queue = self.queue
        try:
            for raw in iter(stdin.readline, b""):
                try:
                    loop.call_soon_threadsafe(queue.put_nowait, raw)
                except RuntimeError:
                    return
        except (OSError, ValueError):
            pass
        try:
            loop.call_soon_threadsafe(queue.put_nowait, None)
        except RuntimeError:
            pass

    def _parse(self, raw: bytes) -> Optional[Dict[str, Any]]:
        text = raw.decode("utf-8", errors="replace").strip()
        if not text:
            return None
        try:
            req = json.loads(text)
        except ValueError as exc:
            log("error", "invalid request JSON: %s" % exc)
            send_event("log", {"level": "error", "message": "invalid request JSON: %s" % exc})
            return None
        if not isinstance(req, dict) or not isinstance(req.get("method"), str):
            rid = req.get("id") if isinstance(req, dict) else None
            if rid is not None:
                send({"id": rid, "error": {"code": "invalid_request", "message": "missing method"}})
            return None
        return req

    async def _dispatch(self, req: Dict[str, Any]) -> None:
        rid = req.get("id")
        method = req["method"]
        params = req.get("params") or {}
        handler = getattr(self, "m_" + method, None)
        if handler is None:
            if rid is not None:
                send({"id": rid, "error": {"code": "invalid_request", "message": "unknown method %r" % method}})
            return
        try:
            result = await handler(params)
            if rid is not None:
                send({"id": rid, "result": result if result is not None else {}})
        except BridgeError as exc:
            if rid is not None:
                send({"id": rid, "error": {"code": exc.code, "message": exc.message}})
        except Exception as exc:  # noqa: BLE001
            tb = traceback.format_exc()
            log("error", tb)
            if rid is not None:
                send({"id": rid, "error": {"code": "internal", "message": "%s: %s" % (type(exc).__name__, exc)}})

    async def cleanup(self) -> None:
        for t in self.tasks:
            t.cancel()
        if self.km is not None:
            try:
                if await self.km.is_alive():
                    try:
                        await asyncio.wait_for(self.km.shutdown_kernel(now=False), 3)
                    except Exception:  # noqa: BLE001
                        await self.km.shutdown_kernel(now=True)
            except Exception as exc:  # noqa: BLE001
                log("warn", "kernel shutdown: %s" % exc)
        if self.kc is not None:
            try:
                self.kc.stop_channels()
            except Exception:  # noqa: BLE001
                pass

    # -- kernel I/O --------------------------------------------------------

    def _set_state(self, state: str) -> None:
        if state != self.kernel_state:
            self.kernel_state = state
            send_event("status", {"state": state})

    async def _iopub_loop(self) -> None:
        kc = self.kc
        while True:
            try:
                msg = await kc.get_iopub_msg()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                log("error", "iopub: %s" % exc)
                await asyncio.sleep(0.05)
                continue
            msg_type = msg.get("msg_type") or msg.get("header", {}).get("msg_type")
            parent = (msg.get("parent_header") or {}).get("msg_id")
            content = msg.get("content") or {}
            if msg_type == "status":
                state = content.get("execution_state")
                if parent in self.idle and state == "idle":
                    self.idle[parent].set()
                if state in ("busy", "idle") and not self.restarting:
                    self._set_state(state)
                continue
            if msg_type in OUTPUT_MSG_TYPES:
                send_event(
                    "iopub",
                    {
                        "cell_id": self.routes.get(parent),
                        "msg_type": msg_type,
                        "content": content,
                        "metadata": msg.get("metadata") or {},
                    },
                )

    async def _shell_loop(self) -> None:
        kc = self.kc
        while True:
            try:
                msg = await kc.get_shell_msg()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                log("error", "shell: %s" % exc)
                await asyncio.sleep(0.05)
                continue
            parent = (msg.get("parent_header") or {}).get("msg_id")
            fut = self.replies.pop(parent, None)
            if fut is not None and not fut.done():
                fut.set_result(msg)

    async def _monitor_loop(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            if self.restarting or self.km is None:
                continue
            try:
                alive = await self.km.is_alive()
            except Exception:  # noqa: BLE001
                alive = False
            if not alive and not self.dead:
                self.dead = True
                log("error", "kernel died")
                self._set_state("dead")
                self._fail_pending("kernel_dead", "The kernel died unexpectedly")

    def _fail_pending(self, code: str, message: str) -> None:
        replies, self.replies = self.replies, {}
        for fut in replies.values():
            if not fut.done():
                fut.set_exception(BridgeError(code, message))
        for ev in self.idle.values():
            ev.set()

    def _request(self, msg_id: str) -> asyncio.Future:
        assert self.loop is not None
        fut = self.loop.create_future()
        self.replies[msg_id] = fut
        return fut

    async def _wait_ready(self, timeout: float) -> Dict[str, Any]:
        """Send kernel_info until the kernel answers on shell *and* iopub.

        iopub is a PUB/SUB socket: until our subscription has reached the kernel,
        its messages are silently dropped, so the first cell's output could be lost
        (seen on fast Linux machines). Seeing the iopub "idle" status for our own
        kernel_info request proves the subscription is live.
        """
        assert self.loop is not None
        deadline = self.loop.time() + timeout
        info: Optional[Dict[str, Any]] = None
        while True:
            msg_id = self.kc.kernel_info()
            fut = self._request(msg_id)
            idle = asyncio.Event()
            self.idle[msg_id] = idle
            try:
                reply = await asyncio.wait_for(asyncio.shield(fut), 1.0)
                info = reply.get("content") or {}
                await asyncio.wait_for(idle.wait(), 0.5)
                return info
            except asyncio.TimeoutError:
                self.replies.pop(msg_id, None)
                if info is not None and self.loop.time() > deadline:
                    return info  # kernel answers but iopub stays silent: go on anyway
                if not await self.km.is_alive():
                    raise BridgeError(
                        "start_failed", "kernel process exited during startup (see :Cellbook log)"
                    ) from None
                if self.loop.time() > deadline:
                    raise BridgeError(
                        "start_failed", "kernel did not reply to kernel_info within %ds" % timeout
                    ) from None
            finally:
                self.idle.pop(msg_id, None)

    def _require_kernel(self) -> None:
        if self.km is None or self.kc is None:
            raise BridgeError("busy", "no kernel started")
        if self.dead:
            raise BridgeError("kernel_dead", "The kernel is dead; restart it")

    # -- methods -----------------------------------------------------------

    async def m_ping(self, params: Dict[str, Any]) -> Dict[str, Any]:
        return {"alive": True, "kernel_state": self.kernel_state}

    async def m_list_kernelspecs(self, params: Dict[str, Any]) -> Dict[str, Any]:
        from jupyter_client.kernelspec import KernelSpecManager

        specs = []
        for name, info in sorted(KernelSpecManager().get_all_specs().items()):
            spec = info.get("spec", {})
            specs.append(
                {
                    "name": name,
                    "display_name": spec.get("display_name", name),
                    "language": spec.get("language", ""),
                    "argv": spec.get("argv", []),
                    "resource_dir": info.get("resource_dir", ""),
                }
            )
        return {"specs": specs}

    async def m_start_kernel(self, params: Dict[str, Any]) -> Dict[str, Any]:
        from jupyter_client.kernelspec import NoSuchKernel
        from jupyter_client.manager import AsyncKernelManager

        if self.km is not None:
            raise BridgeError("busy", "a kernel is already running in this bridge")
        name = params.get("kernel_name") or "python3"
        cwd = params.get("cwd") or os.getcwd()
        env = dict(os.environ)
        env.update({str(k): str(v) for k, v in (params.get("env") or {}).items()})
        # The kernel must not inherit our protocol pipe as stdout.
        env.setdefault("PYDEVD_DISABLE_FILE_VALIDATION", "1")
        km = AsyncKernelManager(kernel_name=name)
        self._set_state("starting")
        if params.get("native"):
            # Run ipykernel in the bridge's own interpreter (the environment the
            # user selected), ignoring any user-installed "python3" kernelspec.
            from jupyter_client.kernelspec import KernelSpec

            km._kernel_spec = KernelSpec(
                argv=[sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
                display_name="Python %d.%d.%d" % sys.version_info[:3],
                language="python",
                metadata={"debugger": True},
            )
        try:
            _ = km.kernel_spec
        except NoSuchKernel:
            self.kernel_state = "none"
            raise BridgeError("no_such_kernel", "No such kernel: %s" % name) from None
        try:
            await km.start_kernel(cwd=cwd, env=env, stdout=sys.stderr, stderr=sys.stderr)
        except NoSuchKernel:
            self.kernel_state = "none"
            raise BridgeError("no_such_kernel", "No such kernel: %s" % name) from None
        except Exception as exc:  # noqa: BLE001
            self.kernel_state = "none"
            log("error", traceback.format_exc())
            raise BridgeError("start_failed", "failed to start kernel %s: %s" % (name, exc)) from exc
        self.km = km
        kc = km.client()
        kc.start_channels()
        self.kc = kc
        self.tasks = [
            asyncio.ensure_future(self._iopub_loop()),
            asyncio.ensure_future(self._shell_loop()),
            asyncio.ensure_future(self._monitor_loop()),
        ]
        info = await self._wait_ready(float(params.get("timeout") or 60))
        self.dead = False
        self._set_state("idle")
        spec = km.kernel_spec
        return {
            "kernel_id": getattr(km, "kernel_id", None) or "",
            "kernel_name": name,
            "display_name": getattr(spec, "display_name", name),
            "language": getattr(spec, "language", ""),
            "language_info": info.get("language_info") or {},
            "implementation": info.get("implementation"),
        }

    async def m_execute(self, params: Dict[str, Any]) -> Dict[str, Any]:
        self._require_kernel()
        code = params.get("code", "")
        msg_id = self.kc.execute(
            code,
            silent=bool(params.get("silent", False)),
            store_history=bool(params.get("store_history", True)),
            allow_stdin=False,
            stop_on_error=bool(params.get("stop_on_error", True)),
        )
        self.routes[msg_id] = params.get("cell_id")
        self.idle[msg_id] = asyncio.Event()
        fut = self._request(msg_id)
        try:
            reply = await fut
            # iopub output for this request must reach Lua before the reply
            try:
                await asyncio.wait_for(self.idle[msg_id].wait(), 5.0)
            except asyncio.TimeoutError:
                log("warn", "no idle status for %s" % msg_id)
        finally:
            self.idle.pop(msg_id, None)
        content = reply.get("content") or {}
        return {
            "msg_id": msg_id,
            "status": content.get("status", "error"),
            "execution_count": content.get("execution_count"),
            "ename": content.get("ename"),
            "evalue": content.get("evalue"),
        }

    async def m_interrupt(self, params: Dict[str, Any]) -> Dict[str, Any]:
        self._require_kernel()
        await self.km.interrupt_kernel()
        return {}

    async def m_restart(self, params: Dict[str, Any]) -> Dict[str, Any]:
        if self.km is None:
            raise BridgeError("busy", "no kernel started")
        self.restarting = True
        self._set_state("restarting")
        self._fail_pending("kernel_restarted", "The kernel was restarted")
        try:
            await self.km.restart_kernel(now=bool(params.get("now", False)))
            info = await self._wait_ready(float(params.get("timeout") or 60))
        except BridgeError:
            self.restarting = False
            raise
        except Exception as exc:  # noqa: BLE001
            self.restarting = False
            log("error", traceback.format_exc())
            raise BridgeError("start_failed", "restart failed: %s" % exc) from exc
        self.restarting = False
        self.dead = False
        self.kernel_state = "restarting"
        self._set_state("idle")
        return {"language_info": info.get("language_info") or {}}

    async def m_shutdown(self, params: Dict[str, Any]) -> Dict[str, Any]:
        if self.km is not None:
            self._set_state("shutdown")
        await self.cleanup()
        self.km = None
        self.kc = None
        self.tasks = []
        return {}

    async def m_render_image(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Downscale an image to a grid of terminal cells (works without a kernel).

        mode "half": each cell shows 2 stacked pixels ("▀": fg = top, bg = bottom);
        rows of [top, bottom] 0xRRGGBB pairs.
        mode "sextant": each cell shows 2x3 sub-pixels in two colours; rows of
        [pattern, fg, bg] where bit i of pattern (i = 0..5, row-major) is fg.
        """
        try:
            from PIL import Image  # noqa: PLC0415
        except ImportError:
            raise BridgeError("missing_dependency", "Pillow is not installed in the bridge environment") from None
        import base64
        import io

        data = params.get("data") or ""
        cols = max(4, int(params.get("cols") or 80))
        max_rows = max(2, int(params.get("max_rows") or 24))
        bg = params.get("background")
        mode = params.get("mode") or "half"
        loop = asyncio.get_running_loop()

        def work() -> Dict[str, Any]:
            raw = base64.b64decode("".join(data.split()))
            img = Image.open(io.BytesIO(raw))
            src_w, src_h = img.size
            img = img.convert("RGBA")
            canvas = Image.new("RGBA", img.size, tuple(bg) + (255,) if bg else (255, 255, 255, 255))
            canvas.alpha_composite(img)
            img = canvas.convert("RGB")
            # terminal cells are ~1:2 (width:height)
            c = min(cols, src_w)
            r = max(1, round(c * src_h / src_w / 2))
            if r > max_rows:
                r = max_rows
                c = max(4, round(r * 2 * src_w / src_h))
            if mode == "sextant":
                return {"width": src_w, "height": src_h, "cols": c, "mode": "sextant", "rows": sextants(img, c, r)}
            img = img.resize((c, r * 2), Image.LANCZOS)
            px = img.load()
            rows = []
            for y in range(0, r * 2, 2):
                row = []
                for x in range(c):
                    t = px[x, y]
                    b = px[x, y + 1]
                    row.append([(t[0] << 16) | (t[1] << 8) | t[2], (b[0] << 16) | (b[1] << 8) | b[2]])
                rows.append(row)
            return {"width": src_w, "height": src_h, "cols": c, "mode": "half", "rows": rows}

        def sextants(img: Any, c: int, r: int) -> list:
            """2x3 sub-pixels per cell, two colours per cell -> [pattern, fg, bg]."""
            img = img.resize((c * 2, r * 3), Image.LANCZOS)
            px = img.load()

            def lum(p: Any) -> float:
                return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]

            def avg(ps: list) -> int:
                n = len(ps)
                return (
                    (sum(p[0] for p in ps) // n << 16)
                    | (sum(p[1] for p in ps) // n << 8)
                    | (sum(p[2] for p in ps) // n)
                )

            rows = []
            for cy in range(r):
                row = []
                for cx in range(c):
                    cell = [px[cx * 2 + (i & 1), cy * 3 + (i >> 1)] for i in range(6)]
                    ls = [lum(p) for p in cell]
                    lo, hi = min(ls), max(ls)
                    if hi - lo < 10:
                        row.append([0, 0, avg(cell)])
                        continue
                    dark = cell[ls.index(lo)]
                    light = cell[ls.index(hi)]
                    pattern, fg_px, bg_px = 0, [], []
                    for i, p in enumerate(cell):
                        dd = sum((p[k] - dark[k]) ** 2 for k in range(3))
                        dl = sum((p[k] - light[k]) ** 2 for k in range(3))
                        if dd <= dl:
                            pattern |= 1 << i
                            fg_px.append(p)
                        else:
                            bg_px.append(p)
                    row.append([pattern, avg(fg_px), avg(bg_px) if bg_px else avg(fg_px)])
                rows.append(row)
            return rows

        try:
            return await loop.run_in_executor(None, work)
        except BridgeError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise BridgeError("invalid_request", "cannot decode image: %s" % exc) from exc

    async def m_complete(self, params: Dict[str, Any]) -> Dict[str, Any]:
        self._require_kernel()
        msg_id = self.kc.complete(params.get("code", ""), params.get("cursor_pos"))
        reply = await asyncio.wait_for(self._request(msg_id), 10)
        return reply.get("content") or {}

    async def m_inspect(self, params: Dict[str, Any]) -> Dict[str, Any]:
        self._require_kernel()
        msg_id = self.kc.inspect(params.get("code", ""), params.get("cursor_pos"), int(params.get("detail_level", 0)))
        reply = await asyncio.wait_for(self._request(msg_id), 10)
        return reply.get("content") or {}


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------


def check() -> Dict[str, Any]:
    """Environment report for :checkhealth (printed as one JSON line)."""
    report = {
        "python": sys.executable,
        "python_version": "%d.%d.%d" % sys.version_info[:3],
        "bridge_version": BRIDGE_VERSION,
        "protocol": PROTOCOL,
        "jupyter_client": None,
        "ipykernel": None,
        "specs": [],
        "errors": [],
    }
    try:
        import jupyter_client

        report["jupyter_client"] = getattr(jupyter_client, "__version__", "?")
        from jupyter_client.kernelspec import KernelSpecManager

        for name, info in sorted(KernelSpecManager().get_all_specs().items()):
            spec = info.get("spec", {})
            report["specs"].append(
                {"name": name, "display_name": spec.get("display_name", name), "language": spec.get("language", "")}
            )
    except Exception as exc:  # noqa: BLE001
        report["errors"].append("%s: %s" % (type(exc).__name__, exc))
    try:
        import ipykernel

        report["ipykernel"] = getattr(ipykernel, "__version__", "?")
    except Exception:  # noqa: BLE001
        pass
    return report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="cellbook.nvim Jupyter kernel bridge")
    ap.add_argument("--protocol", type=int, default=PROTOCOL)
    ap.add_argument("--check", action="store_true", help="print an environment report and exit")
    ap.add_argument("--version", action="store_true")
    args = ap.parse_args(argv)

    _setup_stdout()

    if args.version:
        send({"bridge_version": BRIDGE_VERSION, "protocol": PROTOCOL})
        return 0
    if args.check:
        send(check())
        return 0
    if args.protocol != PROTOCOL:
        send_event(
            "fatal",
            {
                "code": "protocol_mismatch",
                "message": "bridge speaks protocol %d, plugin requested %d" % (PROTOCOL, args.protocol),
                "fix": "update cellbook.nvim so the plugin and bridge match",
            },
        )
        return 4
    try:
        import jupyter_client  # noqa: F401
    except ImportError as exc:
        send_event("fatal", {"code": "missing_dependency", "message": str(exc), "fix": FIX_COMMAND})
        return 3

    bridge = Bridge()
    if sys.platform == "win32":
        # pyzmq's asyncio integration needs a selector event loop on Windows.
        if sys.version_info >= (3, 12):
            return asyncio.run(bridge.run(), loop_factory=asyncio.SelectorEventLoop)  # type: ignore[call-arg]
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())  # type: ignore[attr-defined]
    return asyncio.run(bridge.run())


def _exit(code: int) -> None:
    # Skip interpreter teardown: the stdin reader thread and zmq contexts can
    # crash during finalization on some platforms. Everything is already flushed.
    try:
        sys.stderr.flush()
    finally:
        os._exit(code)


if __name__ == "__main__":
    try:
        _exit(main())
    except KeyboardInterrupt:
        _exit(130)
