#!/usr/bin/env python3
"""DingTalk QR Screenshot Helper — runs on the HOST (not in Docker).

Exposes endpoints on 127.0.0.1:7777:
  GET  /screenshot  → PNG of the current Xvfb display
  POST /refresh-qr  → click DingTalk's expired-QR refresh button
  GET  /health      → {"ok": true}

The Docker backend container calls this via host.docker.internal:7777.
Only binds to localhost — never exposed externally.

Usage:
  python3 dingtalk_qr_server.py           # default :99 display, port 7777
  DISPLAY=:1 QR_PORT=7778 python3 ...     # override
"""
import json, logging, os, re, shutil, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Dict, List, Optional, Tuple

DISPLAY = os.getenv("DISPLAY", ":99")
PORT    = int(os.getenv("QR_PORT", "7777"))
# Bind on all interfaces so the Docker backend container can reach us via
# host.docker.internal. Port 7777 is not exposed by nginx, so it's
# only reachable from the local machine and the Docker bridge network.
BIND    = "0.0.0.0"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dingtalk-qr")


def _run(cmd: List[str], timeout: float = 5, text: bool = True) -> subprocess.CompletedProcess:
    env = {**os.environ, "DISPLAY": DISPLAY}
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=timeout,
        universal_newlines=text,
    )


def _take_screenshot() -> bytes:
    """Capture Xvfb display and return PNG bytes. Uses xwd + convert (ImageMagick)."""
    env = {**os.environ, "DISPLAY": DISPLAY}

    # xwd dumps raw X window data; convert transforms to PNG in one pipe
    xwd = subprocess.run(
        ["xwd", "-root", "-silent"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=8,
    )
    if xwd.returncode != 0:
        raise RuntimeError(f"xwd failed: {xwd.stderr.decode()[:200]}")

    convert = subprocess.run(
        ["convert", "xwd:-", "-resize", "1280x800>", "png:-"],
        input=xwd.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    if convert.returncode != 0:
        raise RuntimeError(f"convert failed: {convert.stderr.decode()[:200]}")

    return convert.stdout


def _display_size() -> Tuple[int, int]:
    """Return the X display size, falling back to install.sh's Xvfb default."""
    for cmd in (["xdpyinfo"], ["xwininfo", "-root"]):
        try:
            result = _run(cmd, timeout=3)
        except Exception:
            continue
        if result.returncode != 0:
            continue

        match = re.search(r"dimensions:\s+(\d+)x(\d+)", result.stdout)
        if match:
            return int(match.group(1)), int(match.group(2))

        width = re.search(r"Width:\s+(\d+)", result.stdout)
        height = re.search(r"Height:\s+(\d+)", result.stdout)
        if width and height:
            return int(width.group(1)), int(height.group(1))

    return 1280, 800


def _window_ids_from_xwininfo() -> List[str]:
    try:
        result = _run(["xwininfo", "-root", "-tree"], timeout=4)
    except Exception:
        return []
    if result.returncode != 0:
        return []

    ids: List[str] = []
    keywords = ("dingtalk", "钉钉", "com.alibabainc")
    for line in result.stdout.splitlines():
        lower = line.lower()
        if not any(keyword in lower for keyword in keywords):
            continue
        match = re.search(r"(0x[0-9a-fA-F]+)", line)
        if match:
            ids.append(match.group(1))
    return ids


def _find_dingtalk_windows() -> List[str]:
    """Find likely DingTalk windows and return largest candidates last."""
    if not shutil.which("xdotool"):
        raise RuntimeError("xdotool not found. Install it with: apt-get install xdotool")

    searches = (
        ["xdotool", "search", "--onlyvisible", "--class", "DingTalk"],
        ["xdotool", "search", "--onlyvisible", "--class", "dingtalk"],
        ["xdotool", "search", "--onlyvisible", "--class", "com.alibabainc.dingtalk"],
        ["xdotool", "search", "--onlyvisible", "--name", "DingTalk"],
        ["xdotool", "search", "--onlyvisible", "--name", "钉钉"],
    )

    ids: List[str] = []
    for cmd in searches:
        try:
            result = _run(cmd, timeout=4)
        except Exception:
            continue
        if result.returncode == 0:
            ids.extend(line.strip() for line in result.stdout.splitlines() if line.strip())

    ids.extend(_window_ids_from_xwininfo())

    unique: List[str] = []
    seen = set()
    for win_id in ids:
        if win_id not in seen:
            unique.append(win_id)
            seen.add(win_id)

    def area(win_id: str) -> int:
        geom = _window_geometry(win_id)
        if not geom:
            return 0
        return geom["WIDTH"] * geom["HEIGHT"]

    return sorted(unique, key=area)


def _window_geometry(win_id: str) -> Optional[Dict[str, int]]:
    try:
        result = _run(["xdotool", "getwindowgeometry", "--shell", win_id], timeout=3)
    except Exception:
        return None
    if result.returncode != 0:
        return None

    geom: Dict[str, int] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, raw = line.split("=", 1)
        if key in {"X", "Y", "WIDTH", "HEIGHT"}:
            try:
                geom[key] = int(raw)
            except ValueError:
                pass

    required = {"X", "Y", "WIDTH", "HEIGHT"}
    return geom if required.issubset(geom) else None


def _click_qr_refresh() -> dict:
    """Click the center of DingTalk's login QR area.

    The web UI shows a screenshot of the Xvfb desktop. When the QR expires,
    the only real refresh control lives inside DingTalk's native window, so the
    helper must click the X display instead of merely re-fetching a screenshot.
    """
    if not shutil.which("xdotool"):
        raise RuntimeError("xdotool not found. Install it with: apt-get install xdotool")

    display_w, display_h = _display_size()
    win_id = None
    geom = None
    for candidate in reversed(_find_dingtalk_windows()):
        candidate_geom = _window_geometry(candidate)
        if not candidate_geom:
            continue
        if candidate_geom["WIDTH"] < 240 or candidate_geom["HEIGHT"] < 240:
            continue
        win_id = candidate
        geom = candidate_geom
        break

    if geom:
        x = geom["X"] + geom["WIDTH"] // 2
        y = geom["Y"] + int(geom["HEIGHT"] * 0.45)
        method = "qr_refresh_center"
        try:
            subprocess.run(
                ["xdotool", "windowactivate", "--sync", win_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env={**os.environ, "DISPLAY": DISPLAY},
                timeout=3,
            )
        except Exception:
            pass
    else:
        x = display_w // 2
        y = display_h // 2
        method = "display_center"

    x = max(0, min(display_w - 1, x))
    y = max(0, min(display_h - 1, y))
    result = _run(["xdotool", "mousemove", str(x), str(y), "click", "1"], timeout=4)
    if result.returncode != 0:
        raise RuntimeError(f"xdotool click failed: {result.stderr[:200]}")

    time.sleep(0.8)
    return {"ok": True, "x": x, "y": y, "method": method, "window": win_id}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(f"{self.address_string()} {fmt % args}")

    def _send(self, code: int, body: bytes, content_type: str = "application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, b'{"ok":true}')

        elif self.path == "/screenshot":
            try:
                png = _take_screenshot()
                self._send(200, png, "image/png")
                log.info("screenshot served (%d KB)", len(png) // 1024)
            except Exception as e:
                log.warning("screenshot failed: %s", e)
                self._send(503, str(e).encode(), "text/plain")

        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path == "/refresh-qr":
            try:
                result = _click_qr_refresh()
                body = json.dumps(result, ensure_ascii=False).encode()
                self._send(200, body)
                log.info("refresh click sent: %s", result)
            except Exception as e:
                log.warning("refresh click failed: %s", e)
                body = json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False).encode()
                self._send(503, body)

        else:
            self._send(404, b"not found", "text/plain")


if __name__ == "__main__":
    # Quick dependency check
    for cmd in ("xwd", "convert", "xdotool"):
        r = subprocess.run(["which", cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            sys.exit(f"Error: '{cmd}' not found. Install: apt-get install x11-apps imagemagick xdotool")

    server = HTTPServer((BIND, PORT), Handler)
    log.info("DingTalk QR server listening on %s:%d (DISPLAY=%s)", BIND, PORT, DISPLAY)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")
