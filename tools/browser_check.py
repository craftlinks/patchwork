#!/usr/bin/env python3
"""Browser check: an app's scenario replayed in Chromium against its headless regress frame.

Usage: python3 -I tools/browser_check.py <app> <scenario> [--keep] [--port N] [--cdp N] [--reuse]
       [--root DIR] [--headless]

`--root DIR` names the tree that holds the app: its `zig-out/bin/<app>`, its golden files, and its
`serve-<app>` step, for an app in a package of its own (Weft's Play, or `examples/sound` for the
audio and rack examples). The default is this
repository, so every other use is unchanged. Every path and step below is under that root.

1. Renders the scenario headless on the high adapter with `zig-out/bin/<app> --regress --only
   <scenario> --adapter high --keep`, which leaves the reference frame in
   `zig-out/regress/<app>/<scenario>-high-on.png` (build the examples first with
   `zig build -Doptimize=ReleaseFast`).
2. Starts its own `zig build serve-<app>`, which builds the wasm from
   this tree, on a free port (or `--port`) through `PATCHWORK_SERVE_PORT` (src/serve.zig), and
   waits for it. It never uses a server it did not start, since one already on a port may serve
   another tree's or an older build (another session in this repository runs its own), unless
   `--reuse` says to use the one on `--port` (default 8080) as it is.
3. Starts system Chromium with WebGPU and remote debugging on a free port (or `--cdp`), sets
   the viewport to the app's regress size at scale 1 (the `WxH` of the headless run's first
   line, `regress <app>  WxH@1.00`; 1280 x 720 unless the app declares `regress_size`), loads
   `?bench=<scenario>` (web/shell.js, section 8a), and asks the page for one animation frame.
   None within `FRAME_TIMEOUT_S` means the compositor is not showing the window (a window on a
   workspace that is not shown gets no frame, so the replay never starts): the check stops
   with "the page drew no frame" and exit status 3. Otherwise it waits for the console line
   `bench done <scenario>` (none within `DONE_TIMEOUT_S`: "the scenario did not finish", exit
   status 1) and screenshots the canvas at the regress size.
   `--headless` runs Chromium's new headless mode instead of a window, so nothing shows on the
   screen and no workspace can hide it; its flags give WebGPU the hardware Vulkan adapter
   (`HEADLESS_FLAGS`). It compares the canvas's last frame (`toDataURL`) in place of the
   screenshot, which headless Chromium takes without the WebGPU canvas.
   A windowed run is exact only when the compositor gives the window at least the regress
   size: a tiled window narrower than the viewport is scaled to fit, and the screenshot then
   differs on the edges of the text. `--headless` has no window, so any size passes as the
   frame does.
4. Prints `differ N px, max level M`; passes when M <= 3 and N <= 0.1% of the pixels (Tint and
   naga round trigonometry differently). On a failure, or with --keep, writes the screenshot
   and a diff picture beside the reference (`<scenario>-browser.png`, `.diff.png`).
5. Reports console errors and warnings (an error fails the check) and stops what it started,
   its whole process groups, also on SIGTERM, SIGHUP, or Ctrl+C. It never kills a process it did
   not start; a port still taken afterwards is reported with its pid.

Python standard library only, so it runs with `python3 -I`. Exit status 0 on a pass, 1 on a
failure, 2 on a usage or setup error, 3 when the page drew no frame.
"""

import base64
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEVEL_MAX = 3
SHARE_MAX = 0.001
DONE_TIMEOUT_S = 60
SERVE_TIMEOUT_S = 300
LOAD_TIMEOUT_S = 30
FRAME_TIMEOUT_S = 5
NO_FRAME_STATUS = 3
# Chromium's new headless mode with WebGPU on the hardware adapter. Without
# `--disable-gpu-compositing` the page gets no adapter ("A valid external Instance reference no
# longer exists"), and without `--use-angle=vulkan` it gets SwiftShader, Chromium's CPU one.
HEADLESS_FLAGS = (
    "--headless=new",
    "--use-angle=vulkan",
    "--disable-gpu-compositing",
)
# The windowed run: a Wayland window the compositor shows.
WINDOW_FLAGS = ("--ozone-platform=wayland",)


class Cdp:
    """A raw-socket Chrome DevTools Protocol client for one page."""

    def __init__(self, port, url_part):
        pages = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
        page = [p for p in pages if p["type"] == "page" and url_part in p["url"]][0]
        path = page["webSocketDebuggerUrl"].split(f"127.0.0.1:{port}")[1]
        self.sock = socket.create_connection(("127.0.0.1", port))
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.send(
            (
                f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.sock.recv(4096)
        self.buf = self.buf.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0
        self.logs = []
        self.events = set()
        self.replies = {}

    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header = bytes([0x81, 0x80 | n])
        elif n < 65536:
            header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
        else:
            header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n)
        self.sock.send(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("devtools socket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        message = b""
        while True:
            head = self.recv_exact(2)
            n = head[1] & 0x7F
            if n == 126:
                n = struct.unpack(">H", self.recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self.recv_exact(8))[0]
            message += self.recv_exact(n)
            if head[0] & 0x80:
                return json.loads(message)

    def note(self, message):
        method = message.get("method")
        if method is not None:
            self.events.add(method)
        elif "id" in message:
            self.replies[message["id"]] = message
        if method == "Runtime.consoleAPICalled":
            args = message["params"]["args"]
            text = " ".join(str(a.get("value", a.get("description", ""))) for a in args)
            self.logs.append((message["params"]["type"], text))
        elif method == "Runtime.exceptionThrown":
            details = message["params"]["exceptionDetails"]
            self.logs.append(("exception", json.dumps(details)[:300]))

    def call(self, method, params=None):
        self.next_id += 1
        self.send({"id": self.next_id, "method": method, "params": params or {}})
        while True:
            message = self.recv()
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result", {})
            self.note(message)

    def call_within(self, method, params, seconds):
        """`call`, but gives up after `seconds`; returns the result, or None when no reply came."""
        self.next_id += 1
        sent = self.next_id
        self.send({"id": sent, "method": method, "params": params})
        if not self.pump_until(lambda _: sent in self.replies, seconds):
            return None
        reply = self.replies.pop(sent)
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']}")
        return reply.get("result", {})

    def pump_until(self, predicate, seconds):
        """Reads events until `predicate(logs)` holds or `seconds` pass; returns whether it held."""
        end = time.time() + seconds
        self.sock.settimeout(0.05)
        try:
            while time.time() < end:
                if predicate(self.logs):
                    return True
                try:
                    self.note(self.recv())
                except socket.timeout:
                    pass
            return predicate(self.logs)
        finally:
            self.sock.settimeout(None)


def png_decode(data):
    """8-bit RGB or RGBA PNG -> (width, height, RGB bytes); every filter type."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    at = 8
    idat = b""
    width = height = color = None
    while at < len(data):
        n = struct.unpack(">I", data[at : at + 4])[0]
        kind = data[at + 4 : at + 8]
        body = data[at + 8 : at + 8 + n]
        at += 12 + n
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0 or color not in (2, 6):
                raise ValueError("unsupported PNG")
        elif kind == b"IDAT":
            idat += body
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * bpp
    prev = bytearray(stride)
    rows = []
    p = 0
    for _ in range(height):
        kind = raw[p]
        line = bytearray(raw[p + 1 : p + 1 + stride])
        p += 1 + stride
        if kind == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif kind == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif kind == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif kind == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + predictor) & 255
        rows.append(bytes(line))
        prev = line
    if bpp == 4:
        rows = [bytes(b for i, b in enumerate(row) if i % 4 != 3) for row in rows]
    return width, height, rows


def png_encode(width, height, rows):
    def chunk(kind, body):
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)

    raw = b"".join(b"\x00" + row for row in rows)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def compare(reference, browser):
    """(differing pixels, max level, diff rows) as `bench.diff_rgb` paints them."""
    differ = 0
    most = 0
    diff_rows = []
    for old, new in zip(reference, browser):
        out = bytearray(len(new))
        same_row = old == new
        for at in range(0, len(new), 3):
            level = 0 if same_row else max(abs(old[at + k] - new[at + k]) for k in range(3))
            if level == 0:
                grey = ((new[at] * 77 + new[at + 1] * 150 + new[at + 2] * 29) >> 8) // 4
                out[at : at + 3] = bytes((grey, grey, grey))
            else:
                differ += 1
                most = max(most, level)
                out[at : at + 3] = bytes((64 + level * 191 // 255, 0, 0))
        diff_rows.append(bytes(out))
    return differ, most, diff_rows


def port_open(port):
    with socket.socket() as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def http_ok(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1) as response:
            return response.status == 200
    except OSError:
        return False


def stop(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def listeners(port):
    """The pids listening on `port` (from `ss`)."""
    listing = subprocess.run(["ss", "-ltnpH", f"sport = :{port}"], capture_output=True, text=True)
    return sorted({int(part.split(",")[0]) for part in listing.stdout.split("pid=")[1:]})


def free_tcp_port():
    """A loopback port nothing listens on now (the kernel's pick for port 0)."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def check_released(port, process):
    """Reports a listener left on `port` by `process`'s group (a bug); kills only that group."""
    if process is None:
        return
    end = time.time() + 5
    while port_open(port) and time.time() < end:
        time.sleep(0.1)
    for pid in listeners(port):
        try:
            ours = os.getpgid(pid) == process.pid
        except ProcessLookupError:
            continue
        if ours:
            print(f"browser_check: pid {pid} of our group still held :{port}; killed")
            os.kill(pid, signal.SIGKILL)
        else:
            print(f"browser_check: :{port} is held by pid {pid}, which this check did not start")


def regress_size(first_line):
    """The `(width, height)` of the headless run's first line, `regress <app>  WxH@S`, or None."""
    match = re.match(r"regress \S+\s+(\d+)x(\d+)@", first_line)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def first_frame(cdp, seconds):
    """Whether the page runs one animation frame within `seconds`. The limit is kept here, not
    by a page timer, since a page that gets no frame may get its timers late too."""
    expression = "new Promise(resolve => requestAnimationFrame(() => resolve(true)))"
    result = cdp.call_within(
        "Runtime.evaluate",
        {"expression": expression, "awaitPromise": True, "returnByValue": True},
        seconds,
    )
    return result is not None and result.get("result", {}).get("value") is True


def canvas_png(cdp):
    """The canvas's last presented frame as PNG bytes (`toDataURL`), or None. Headless Chromium
    composites in software, which leaves a WebGPU canvas out of the page's screenshot."""
    expression = "document.getElementById('surface').toDataURL('image/png')"
    result = cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
    url = result.get("result", {}).get("value", "")
    prefix = "data:image/png;base64,"
    if not isinstance(url, str) or not url.startswith(prefix):
        return None
    return base64.b64decode(url[len(prefix) :])


def exit_on_signal(signum, _frame):
    """Turns SIGTERM and SIGHUP into SystemExit, so `main`'s cleanup runs."""
    raise SystemExit(128 + signum)


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    keep = "--keep" in argv
    reuse = "--reuse" in argv
    headless = "--headless" in argv
    port = None
    cdp_port = None
    root = ROOT
    if "--root" in argv:
        value = argv[argv.index("--root") + 1]
        args.remove(value)
        root = os.path.abspath(os.path.expanduser(value))
        if not os.path.isdir(root):
            print(f"browser_check: --root {root} is not a directory")
            return 2
    for flag in ("--port", "--cdp"):
        if flag in argv:
            value = int(argv[argv.index(flag) + 1])
            args.remove(str(value))
            if flag == "--port":
                port = value
            else:
                cdp_port = value
    if reuse and port is None:
        port = 8080
    if port is None:
        port = free_tcp_port()
    if cdp_port is None:
        cdp_port = free_tcp_port()
    if len(args) != 2:
        print(__doc__.strip().splitlines()[2])
        return 2
    app, scenario = args
    out_dir = os.path.join(root, "zig-out", "regress", app)
    reference_path = os.path.join(out_dir, f"{scenario}-high-on.png")

    exe = os.path.join(root, "zig-out", "bin", app)
    if not os.path.exists(exe):
        print(f"browser_check: {exe} is missing; run zig build -Doptimize=ReleaseFast")
        return 2
    regress = subprocess.run(
        [exe, "--regress", "--only", scenario, "--adapter", "high", "--keep"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    summary = regress.stdout.strip().splitlines()
    print(f"headless: {summary[-1] if summary else regress.stderr.strip()}")
    if not os.path.exists(reference_path):
        print(f"browser_check: no reference frame {reference_path}")
        return 1
    size = regress_size(summary[0]) if summary else None
    if size is None:
        print(f"browser_check: no size on the headless run's first line ({summary[:1]})")
        return 1
    view_width, view_height = size

    server = None
    chromium = None
    profile = tempfile.mkdtemp(prefix="browser_check-")
    signal.signal(signal.SIGTERM, exit_on_signal)
    signal.signal(signal.SIGHUP, exit_on_signal)
    try:
        if reuse:
            if not http_ok(port):
                print(f"browser_check: --reuse, but nothing serves :{port}")
                return 2
            print(f"server: reusing the one on :{port} as it is (it must serve {app})")
        else:
            if port_open(port):
                print(f"browser_check: :{port} is taken; pass another --port, or --reuse")
                return 2
            step = f"serve-{app}"
            print(f"server: zig build {step} on :{port}")
            server = subprocess.Popen(
                [os.environ.get("ZIG", "zig"), "build", step],
                cwd=root,
                env=dict(os.environ, PATCHWORK_SERVE_PORT=str(port)),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            end = time.time() + SERVE_TIMEOUT_S
            while not http_ok(port):
                if time.time() > end or server.poll() is not None:
                    print(f"browser_check: zig build {step} did not serve :{port}")
                    return 1
                time.sleep(0.25)
        if port_open(cdp_port):
            print(f"browser_check: devtools port :{cdp_port} is taken")
            return 2
        url = f"http://127.0.0.1:{port}/?bench={scenario}"
        # A window a little larger than the viewport, so the emulated one fits inside it.
        window = (view_width, view_height) if headless else (view_width + 120, view_height + 180)
        chromium = subprocess.Popen(
            [
                "chromium",
                f"--user-data-dir={profile}",
                f"--remote-debugging-port={cdp_port}",
                "--enable-unsafe-webgpu",
                "--enable-features=Vulkan",
                *(HEADLESS_FLAGS if headless else WINDOW_FLAGS),
                f"--window-size={max(window[0], 1400)},{max(window[1], 900)}",
                "--no-first-run",
                "--mute-audio",
                "--autoplay-policy=no-user-gesture-required",
                url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        end = time.time() + 30
        cdp = None
        while cdp is None:
            try:
                cdp = Cdp(cdp_port, f":{port}/")
            except (OSError, IndexError, ValueError):
                if time.time() > end:
                    print("browser_check: chromium's devtools did not come up")
                    return 1
                time.sleep(0.25)
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        cdp.call(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": view_width,
                "height": view_height,
                "deviceScaleFactor": 1,
                "mobile": False,
            },
        )
        cdp.logs.clear()
        cdp.events.discard("Page.loadEventFired")
        cdp.call("Page.reload", {"ignoreCache": True})
        # A page that gets no frame still loads, so the frame is asked of the reloaded page.
        cdp.pump_until(lambda _: "Page.loadEventFired" in cdp.events, LOAD_TIMEOUT_S)
        if not first_frame(cdp, FRAME_TIMEOUT_S):
            why = (
                "headless Chromium gave it none"
                if headless
                else "its window is not being shown (show its workspace, or pass --headless)"
            )
            print(f"browser_check: the page drew no frame in {FRAME_TIMEOUT_S} s: {why}")
            report_console(cdp.logs)
            return NO_FRAME_STATUS
        done_line = f"bench done {scenario}"
        ended = cdp.pump_until(
            lambda logs: any(t in (done_line, f"bench failed {scenario}") for _, t in logs)
            or any(t.startswith("bench: no scenario") for _, t in logs),
            DONE_TIMEOUT_S,
        )
        if not ended or not any(t == done_line for _, t in cdp.logs):
            print(
                f"browser_check: the scenario did not finish: "
                f"no \"{done_line}\" within {DONE_TIMEOUT_S} s"
            )
            report_console(cdp.logs)
            return 1
        # One more frame for the compositor to show the last present.
        cdp.pump_until(lambda logs: False, 0.3)
        width, height, reference = png_decode(open(reference_path, "rb").read())
        if (width, height) != (view_width, view_height):
            print(f"browser_check: the reference is {width}x{height}, the run said {size}")
            return 1
        if headless:
            shot_bytes = canvas_png(cdp)
            if shot_bytes is None:
                print("browser_check: the canvas gave no PNG")
                return 1
        else:
            shot = cdp.call(
                "Page.captureScreenshot",
                {
                    "format": "png",
                    "clip": {"x": 0, "y": 0, "width": width, "height": height, "scale": 1},
                },
            )
            shot_bytes = base64.b64decode(shot["data"])
        shot_width, shot_height, browser = png_decode(shot_bytes)
        if (shot_width, shot_height) != (width, height):
            print(f"browser_check: screenshot is {shot_width}x{shot_height}, not {width}x{height}")
            return 1
        differ, most, diff_rows = compare(reference, browser)
        share = differ / (width * height)
        passed = most <= LEVEL_MAX and share <= SHARE_MAX
        print(f"differ {differ} px, max level {most} ({share * 100:.4f}% of {width}x{height})")
        if keep or not passed:
            browser_path = os.path.join(out_dir, f"{scenario}-browser.png")
            diff_path = os.path.join(out_dir, f"{scenario}-browser.diff.png")
            open(browser_path, "wb").write(png_encode(width, height, browser))
            open(diff_path, "wb").write(png_encode(width, height, diff_rows))
            print(f"wrote {browser_path} and {diff_path}")
        errors = report_console(cdp.logs)
        if errors:
            passed = False
        print(f"{app} {scenario}: {'pass' if passed else 'FAIL'}")
        return 0 if passed else 1
    finally:
        stop(chromium)
        stop(server)
        check_released(cdp_port, chromium)
        check_released(port, server)
        shutil.rmtree(profile, ignore_errors=True)


def report_console(logs):
    """Prints console errors and warnings; returns how many errors there were."""
    problems = [(kind, text) for kind, text in logs if kind in ("error", "warning", "exception")]
    for kind, text in problems:
        print(f"console {kind}: {text}")
    if not problems:
        print("console: no errors or warnings")
    return sum(1 for kind, _ in problems if kind != "warning")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
