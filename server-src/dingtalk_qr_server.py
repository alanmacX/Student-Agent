#!/usr/bin/env python3
"""DingTalk QR Screenshot Helper — runs on the HOST (not in Docker).

Exposes two endpoints on 127.0.0.1:7777:
  GET /screenshot  → PNG of the current Xvfb display
  GET /health      → {"ok": true}

The Docker backend container calls this via host.docker.internal:7777.
Only binds to localhost — never exposed externally.

Usage:
  python3 dingtalk_qr_server.py           # default :99 display, port 7777
  DISPLAY=:1 QR_PORT=7778 python3 ...     # override
"""
import io, logging, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DISPLAY = os.getenv("DISPLAY", ":99")
PORT    = int(os.getenv("QR_PORT", "7777"))
# Bind on all interfaces so the Docker backend container can reach us via
# host.docker.internal. Port 7777 is not exposed by nginx, so it's
# only reachable from the local machine and the Docker bridge network.
BIND    = "0.0.0.0"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dingtalk-qr")


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


if __name__ == "__main__":
    # Quick dependency check
    for cmd in ("xwd", "convert"):
        r = subprocess.run(["which", cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            sys.exit(f"Error: '{cmd}' not found. Install: apt-get install x11-apps imagemagick")

    server = HTTPServer((BIND, PORT), Handler)
    log.info("DingTalk QR server listening on %s:%d (DISPLAY=%s)", BIND, PORT, DISPLAY)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")
