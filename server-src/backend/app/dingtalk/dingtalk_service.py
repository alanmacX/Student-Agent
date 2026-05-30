import json
import logging
import os
import sqlite3
import struct
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

logger = logging.getLogger("dingtalk")

# DingTalk's fixed AES-128-ECB key from libsync.so — same for all installations.
# Override via env var only if DingTalk changes the key in a future version.
KEY = os.getenv("DINGTALK_AES_KEY", "9f6ac1b97a9021bd").encode()

def _discover_db_path() -> str:
    """Auto-discover the DingTalk SQLite DB by globbing the config dir.

    Supports two env var patterns:
      DINGTALK_DB_SOURCE=/path/to/dingtalk.db   — explicit file path (legacy)
      DINGTALK_DB_SOURCE=/dingtalk_cfg           — config dir, glob for *_v3/DBFiles/dingtalk.db
    """
    import glob
    raw = os.getenv("DINGTALK_DB_SOURCE", "")
    if raw and not raw.endswith("/") and Path(raw).suffix == ".db":
        return raw  # explicit file path

    # Glob inside a config directory (new default: /dingtalk_cfg mounted in docker)
    cfg_dir = raw.rstrip("/") if raw else "/dingtalk_cfg"
    candidates = sorted(glob.glob(f"{cfg_dir}/*_v3/DBFiles/dingtalk.db"))
    if candidates:
        return candidates[0]

    # Fallback: host path (when running outside docker)
    host_candidates = sorted(glob.glob(
        "/root/.config/DingTalk/*_v3/DBFiles/dingtalk.db"
    ))
    return host_candidates[0] if host_candidates else ""

DB_SOURCE = _discover_db_path()
DB_WAL = os.getenv("DINGTALK_DB_WAL", DB_SOURCE + "-wal")
DECRYPTED_DB_PATH = os.getenv("DINGTALK_DECRYPTED_PATH", "/tmp/dingtalk_decrypted.db")
PAGE_SIZE = int(os.getenv("DINGTALK_PAGE_SIZE", "4096"))
WAL_HDR_SIZE = 32
FRAME_HDR_SIZE = 24

# Screenshot helper service on the host (started by install.sh / systemd)
QR_SERVICE_URL = os.getenv("DINGTALK_QR_SERVICE", "")


def is_dingtalk_logged_in() -> bool:
    """True when a DingTalk account DB exists and has user profile data.

    Globs for the account-scoped *_v3 directory under the config mount,
    then decrypts the DB and checks tbuser_profile_v2.
    Note: the encrypted DB file itself may be tiny (4 KB) when all data is
    in the WAL — don't use file size as a proxy for login state.
    """
    import glob
    cfg_dir = os.getenv("DINGTALK_DB_SOURCE", "/dingtalk_cfg").rstrip("/")
    if cfg_dir.endswith(".db"):
        cfg_dir = str(Path(cfg_dir).parent.parent.parent)

    account_dirs = glob.glob(f"{cfg_dir}/*_v3")
    if not account_dirs:
        account_dirs = glob.glob("/root/.config/DingTalk/*_v3")
    if not account_dirs:
        return False

    db = Path(account_dirs[0]) / "DBFiles" / "dingtalk.db"
    if not db.exists():
        return False

    try:
        decrypted = decrypt_db_to_tmp(str(db))
        conn = sqlite3.connect(decrypted)
        count = conn.execute("SELECT COUNT(*) FROM tbuser_profile_v2").fetchone()[0]
        conn.close()
        return count > 0
    except Exception:
        return False


async def fetch_qr_screenshot() -> bytes | None:
    """Fetch a PNG screenshot from the host-side QR helper service.

    Returns raw PNG bytes, or None if the service is unreachable.
    """
    import httpx
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{QR_SERVICE_URL}/screenshot")
            if r.status_code == 200:
                return r.content
    except Exception:
        pass
    return None


def _aes_cipher():
    try:
        from Crypto.Cipher import AES
    except Exception as exc:  # pragma: no cover - depends on deployment image
        raise RuntimeError(
            "pycryptodome is required for DingTalk DB decryption. "
            "Install it with: pip install pycryptodome"
        ) from exc
    return AES.new(KEY, AES.MODE_ECB)


def decrypt_page(page_data: bytes, cipher: Optional[Any] = None) -> bytes:
    if len(page_data) % 16 != 0:
        raise ValueError(f"encrypted page size must be a multiple of 16, got {len(page_data)}")
    # AES-ECB has no chaining between 16-byte blocks, so decrypting the whole
    # page in one call is identical to per-block decryption but ~36x faster
    # (2.66s -> 0.07s on the 11MB WAL). The ECB cipher object is stateless and
    # safe to reuse across pages.
    cipher = cipher or _aes_cipher()
    return cipher.decrypt(page_data)


def decrypt_db_to_tmp(
        source_path: str = DB_SOURCE,
        wal_path: Optional[str] = None,
        output_path: str = DECRYPTED_DB_PATH,
) -> str:
    """Decrypt the DingTalk SQLite DB and apply WAL frames into a temp DB path."""
    wal_path = wal_path if wal_path is not None else source_path + "-wal"
    source = Path(source_path)
    output = Path(output_path)

    if not source.exists():
        raise FileNotFoundError(f"DingTalk DB not found: {source}")

    output.parent.mkdir(parents=True, exist_ok=True)
    tmp_output = output.with_name(f"{output.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}")
    cipher = _aes_cipher()

    try:
        with source.open("rb") as src, tmp_output.open("wb") as dst:
            while True:
                page = src.read(PAGE_SIZE)
                if not page:
                    break
                if len(page) != PAGE_SIZE:
                    logger.warning("Ignoring partial DingTalk DB page of %s bytes", len(page))
                    break
                dst.write(decrypt_page(page, cipher))

        _apply_wal_frames(tmp_output, wal_path, cipher)

        with tmp_output.open("rb+") as db_file:
            db_file.flush()
            os.fsync(db_file.fileno())
        os.replace(tmp_output, output)
    finally:
        try:
            tmp_output.unlink()
        except FileNotFoundError:
            pass

    return str(output)


def _apply_wal_frames(output: Path, wal_path: str, cipher: Any) -> int:
    wal = Path(wal_path)
    if not wal.exists() or wal.stat().st_size <= WAL_HDR_SIZE:
        return 0

    applied = 0
    with wal.open("rb") as wal_file, output.open("r+b") as dst:
        wal_file.seek(WAL_HDR_SIZE)
        while True:
            header = wal_file.read(FRAME_HDR_SIZE)
            if len(header) < FRAME_HDR_SIZE:
                break
            page = wal_file.read(PAGE_SIZE)
            if len(page) < PAGE_SIZE:
                break

            page_no = struct.unpack(">I", header[:4])[0]
            if page_no <= 0:
                continue
            dst.seek((page_no - 1) * PAGE_SIZE)
            dst.write(decrypt_page(page, cipher))
            applied += 1
    return applied


def _connect_readonly(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection, table_name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,),
    ).fetchone()
    return row is not None


def _table_columns(conn: sqlite3.Connection, table_name: str) -> Set[str]:
    if not _table_exists(conn, table_name):
        return set()
    return {row["name"] for row in conn.execute(f'PRAGMA table_info("{table_name}")')}


def _message_tables(conn: sqlite3.Connection) -> List[str]:
    existing = {
        row["name"]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'tbmsg_%'"
        )
    }
    return [name for name in (f"tbmsg_{i:03d}" for i in range(128)) if name in existing]


def _safe_json_text(raw_content: Any) -> Optional[str]:
    if raw_content is None:
        return None
    if isinstance(raw_content, bytes):
        return raw_content.decode("utf-8", errors="replace")
    return str(raw_content)


def _extract_text_and_type(
        raw_content: Any,
        fallback_content_type: Any,
) -> Tuple[Optional[int], Optional[str]]:
    raw = _safe_json_text(raw_content)
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        return _int_or_none(fallback_content_type), raw

    content_type = _int_or_none(payload.get("contentType", fallback_content_type))
    text = payload.get("text")
    if text is None:
        text = payload.get("content")
    if isinstance(text, (dict, list)):
        text = json.dumps(text, ensure_ascii=False)
    elif text is not None:
        text = str(text)
    return content_type, text


def _int_or_none(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _normalize_message(row: sqlite3.Row) -> Dict[str, Any]:
    content_type, text = _extract_text_and_type(row["content"], row["contentType"])
    return {
        "mid": _int_or_none(row["mid"]),
        "cid": row["cid"],
        "conversation_title": row["conversation_title"],
        "sender_id": _int_or_none(row["senderId"]),
        "sender_name": row["sender_name"],
        "content_type": content_type,
        "text": text,
        "raw_content": _safe_json_text(row["content"]),
        "created_at": _int_or_none(row["createdAt"]) or 0,
    }


def get_new_messages(since_timestamp: int) -> List[Dict[str, Any]]:
    """Decrypt latest DB state and return messages with createdAt > since_timestamp."""
    db_path = decrypt_db_to_tmp()
    with _connect_readonly(db_path) as conn:
        return query_new_messages(conn, since_timestamp)


def query_new_messages(conn: sqlite3.Connection, since_timestamp: int) -> List[Dict[str, Any]]:
    tables = _message_tables(conn)
    if not tables:
        return []

    union_sql = " UNION ALL ".join(
        f'SELECT mid, cid, senderId, contentType, content, createdAt FROM "{table}" WHERE createdAt > ?'
        for table in tables
    )
    params = [since_timestamp] * len(tables)

    has_conversation = _table_exists(conn, "tbconversation")
    user_columns = _table_columns(conn, "tbuser_profile_v2")
    has_user = {"uid", "nick"}.issubset(user_columns)

    conversation_join = (
        "LEFT JOIN tbconversation c ON c.cid = m.cid" if has_conversation else ""
    )
    user_join = (
        "LEFT JOIN tbuser_profile_v2 u ON CAST(u.uid AS TEXT) = CAST(m.senderId AS TEXT)"
        if has_user
        else ""
    )
    conversation_title_expr = "c.title" if has_conversation else "NULL"
    sender_name_expr = "u.nick" if has_user else "NULL"

    sql = f"""
        WITH m AS ({union_sql})
        SELECT
            m.mid,
            m.cid,
            {conversation_title_expr} AS conversation_title,
            m.senderId,
            {sender_name_expr} AS sender_name,
            m.contentType,
            m.content,
            m.createdAt
        FROM m
        {conversation_join}
        {user_join}
        ORDER BY m.createdAt ASC, m.mid ASC
    """
    return [_normalize_message(row) for row in conn.execute(sql, params).fetchall()]


def get_conversations() -> List[Dict[str, Any]]:
    db_path = decrypt_db_to_tmp()
    with _connect_readonly(db_path) as conn:
        if not _table_exists(conn, "tbconversation"):
            return []
        rows = conn.execute(
            """
            SELECT cid, title, unreadCount, lastModify
            FROM tbconversation
            ORDER BY lastModify DESC
            """
        ).fetchall()
        return [
            {
                "cid": row["cid"],
                "title": row["title"],
                "unreadCount": _int_or_none(row["unreadCount"]) or 0,
                "lastModify": _int_or_none(row["lastModify"]) or 0,
            }
            for row in rows
        ]


def get_max_message_timestamp() -> int:
    db_path = decrypt_db_to_tmp()
    with _connect_readonly(db_path) as conn:
        tables = _message_tables(conn)
        if not tables:
            return 0
        union_sql = " UNION ALL ".join(f'SELECT MAX(createdAt) AS max_created_at FROM "{t}"' for t in tables)
        row = conn.execute(f"SELECT MAX(max_created_at) AS max_created_at FROM ({union_sql})").fetchone()
        return _int_or_none(row["max_created_at"] if row else None) or 0
