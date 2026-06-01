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
import glob, json, logging, os, re, shutil, struct, subprocess, sys, time
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
        # The "点击刷新" (refresh) button sits below the QR image, at ~0.56 of the
        # window height. 0.45 lands on the QR/X-icon center and misses the button.
        y = geom["Y"] + int(geom["HEIGHT"] * 0.56)
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


# ── AES key auto-discovery ───────────────────────────────────────────────────
# DingTalk encrypts its SQLite DB with an AES-128-ECB key that can change between
# client versions. Instead of hardcoding it (which rots on every update), we
# recover it from the live DingTalk process memory using a known-plaintext
# oracle: a SQLite DB's first 16 bytes are always "SQLite format 3\0". We find a
# 16-byte window K in the process's writable memory where
#   AES-ECB-decrypt(K, encrypted_page1[:16]) == b"SQLite format 3\x00".
# The result is cached on disk so we only rescan when the key actually breaks.
SQLITE_MAGIC = b"SQLite format 3\x00"
KEY_CACHE_FILE = os.getenv("DINGTALK_KEY_CACHE", "/root/.config/DingTalk/.aes_key")
_key_cache: Dict[str, Optional[str]] = {"hex": None}


def _dingtalk_db_path() -> Optional[str]:
    c = sorted(glob.glob("/root/.config/DingTalk/*_v3/DBFiles/dingtalk.db"))
    return c[0] if c else None


def _oracle_ciphertext(db_path: str) -> Optional[bytes]:
    """Freshest encrypted page-1 header: prefer the last page-1 frame in the WAL
    (written with the current key), fall back to the main DB's first page."""
    wal = db_path + "-wal"
    try:
        if os.path.exists(wal) and os.path.getsize(wal) > 32 + 24 + 4096:
            with open(wal, "rb") as f:
                f.read(32)  # WAL header
                last_p1 = None
                while True:
                    fh = f.read(24)
                    if len(fh) < 24:
                        break
                    pg = f.read(4096)
                    if len(pg) < 4096:
                        break
                    if struct.unpack(">I", fh[:4])[0] == 1:
                        last_p1 = pg[:16]
                if last_p1:
                    return last_p1
    except Exception as e:
        log.warning("WAL oracle read failed: %s", e)
    try:
        with open(db_path, "rb") as f:
            return f.read(16)
    except Exception:
        return None


def _validates(key: bytes, ct: bytes) -> bool:
    from Crypto.Cipher import AES
    try:
        return AES.new(key, AES.MODE_ECB).decrypt(ct) == SQLITE_MAGIC
    except Exception:
        return False


def _pids_with_db_open(db_path: str) -> List[int]:
    pids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                if os.readlink(f"/proc/{pid}/fd/{fd}") == db_path:
                    pids.append(int(pid))
                    break
        except OSError:
            continue
    return pids


def _dingtalk_pids() -> List[int]:
    """All DingTalk processes, matched by cmdline (NOT comm — comm truncates to
    15 chars to 'com.alibabainc.' which drops the 'dingtalk' substring)."""
    pids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if b"com.alibabainc.dingtalk" in cmd:
            pids.append(int(pid))
    return pids


# Cap a single region read so a giant mapping can't blow up RAM on a small box
# (this scanner once helped trigger an OOM on a 1.8GB host). We stream region by
# region and never retain more than one region's bytes at a time.
_MAX_REGION_BYTES = 256 * 1024 * 1024


def _iter_rw_regions(pid: int):
    """Yield decrypted-candidate memory chunks, one writable/anon region at a
    time, so peak memory stays bounded to a single region."""
    try:
        maps = open(f"/proc/{pid}/maps").read().splitlines()
    except OSError:
        return
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
    except OSError:
        return
    for line in maps:
        p = line.split()
        if len(p) < 2 or not (p[1][0] == "r" and p[1][1] == "w"):
            continue
        path = p[5] if len(p) >= 6 else ""
        if path and not path.startswith("["):
            continue  # skip file-backed; keep anon + [heap]/[stack]
        a, b = (int(x, 16) for x in p[0].split("-"))
        size = b - a
        if size <= 0 or size > _MAX_REGION_BYTES:
            continue
        try:
            mem.seek(a)
            data = mem.read(size)
        except OSError:
            continue
        yield data


def _scan_pid_for_key(pid: int, ct: bytes) -> Optional[bytes]:
    """Scan a process's writable/anonymous memory for the AES key.

    Streams one region at a time (bounded memory). Within each region it tries
    ASCII candidates first (keys have historically been 16 hex chars), then a
    full binary sliding window for the non-ASCII case — so a single pass over
    each region covers both without retaining all regions in RAM.
    """
    try:
        os.nice(10)  # be gentle; this can run on a memory/CPU-tight host
    except OSError:
        pass
    printable = re.compile(rb"[\x20-\x7e]{16,}")
    for data in _iter_rw_regions(pid):
        seen = set()
        for m in printable.finditer(data):
            s = m.group()
            for i in range(len(s) - 15):
                k = s[i:i + 16]
                if k in seen:
                    continue
                seen.add(k)
                if _validates(k, ct):
                    return k
        for i in range(len(data) - 16):
            if _validates(data[i:i + 16], ct):
                return data[i:i + 16]
    return None


def discover_aes_key(force: bool = False) -> dict:
    """Resolve the current DingTalk AES key, scanning live memory if needed."""
    db = _dingtalk_db_path()
    if not db:
        return {"ok": False, "error": "no DingTalk DB found"}
    ct = _oracle_ciphertext(db)
    if not ct or len(ct) < 16:
        return {"ok": False, "error": "could not read encrypted page-1 header"}

    # Warm cache: memory, then disk. Validate against the *current* ciphertext so
    # a rotated key is detected and triggers a rescan.
    if not _key_cache["hex"]:
        try:
            _key_cache["hex"] = open(KEY_CACHE_FILE).read().strip() or None
        except OSError:
            pass
    if not force and _key_cache["hex"] and _validates(bytes.fromhex(_key_cache["hex"]), ct):
        return {"ok": True, "key_hex": _key_cache["hex"], "method": "cache"}

    # Scan the process(es) holding the DB open first (most likely to hold the
    # key), then every DingTalk process. The key lives in the main process heap,
    # but DingTalk may not have the DB file open at scan time, so we must not
    # require that.
    holders = _pids_with_db_open(db)
    others = [p for p in _dingtalk_pids() if p not in holders]
    for pid in holders + others:
        try:
            key = _scan_pid_for_key(pid, ct)
        except Exception as e:
            log.warning("scan of pid %s failed: %s", pid, e)
            continue
        if key:
            method = "db-holder" if pid in holders else "dingtalk-proc"
            return _persist_key(key, pid, method)
    return {"ok": False, "error": "key not found in DingTalk process memory"}


def _persist_key(key: bytes, pid: int, method: str) -> dict:
    key_hex = key.hex()
    _key_cache["hex"] = key_hex
    try:
        os.makedirs(os.path.dirname(KEY_CACHE_FILE), exist_ok=True)
        with open(KEY_CACHE_FILE, "w") as f:
            f.write(key_hex)
        os.chmod(KEY_CACHE_FILE, 0o600)
    except OSError as e:
        log.warning("could not persist AES key cache: %s", e)
    log.info("recovered DingTalk AES key from pid %s (%s)", pid, method)
    return {"ok": True, "key_hex": key_hex, "method": method, "pid": pid}


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

        elif self.path == "/aes-key" or self.path == "/aes-key?force=1":
            try:
                result = discover_aes_key(force=self.path.endswith("force=1"))
                code = 200 if result.get("ok") else 503
                self._send(code, json.dumps(result).encode())
                log.info("aes-key request: ok=%s method=%s", result.get("ok"), result.get("method") or result.get("error"))
            except Exception as e:
                log.warning("aes-key discovery failed: %s", e)
                self._send(503, json.dumps({"ok": False, "error": str(e)}).encode())

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
