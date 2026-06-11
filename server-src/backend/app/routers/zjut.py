"""ZJUT 正方教务接入端点。

- POST /api/zjut/probe   —— 登录+预览,不落库(调试/首次验证)。
- POST /api/zjut/import  —— 登录→拉取→展开进 server_courses + 考试进 server_events;
                            可选 AES-GCM 加密存凭据(save_credentials)。
- POST /api/zjut/refresh —— 用已存凭据重新导入(手动按钮 / Reconciler 触发用)。
- GET  /api/zjut/status  —— 是否已配置、上次导入时间、是否存了凭据。
全部令牌保护;密码不进日志、不回显。
"""
from __future__ import annotations

from fastapi import APIRouter, Request

from app.config import settings
from app.services import zjut, zjut_import

router = APIRouter(prefix="/api/zjut", tags=["zjut"])


@router.post("/probe")
async def probe(request: Request):
    b = await request.json()
    sid, pw = (b.get("student_id") or "").strip(), b.get("password") or ""
    year, term = (b.get("year") or "").strip(), (b.get("term") or "").strip()
    if not (sid and pw and year and term):
        return {"ok": False, "error": "需要 student_id / password / year(如2025) / term(1|2|3)"}
    try:
        data = await zjut.fetch_timetable_and_exams(sid, pw, year, term)
    except zjut.ZjutError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}
    return {"ok": True, "course_rows": len(data["courses"]), "exam_rows": len(data["exams"]),
            "courses_preview": data["courses"][:8], "exams_preview": data["exams"][:8]}


@router.post("/import")
async def do_import(request: Request):
    b = await request.json()
    sid, pw = (b.get("student_id") or "").strip(), b.get("password") or ""
    year, term = (b.get("year") or "").strip(), (b.get("term") or "").strip()
    week1 = (b.get("week1_monday") or "").strip()
    save = bool(b.get("save_credentials", False))
    if not (sid and pw and year and term and week1):
        return {"ok": False, "error": "需要 student_id / password / year / term / week1_monday(YYYY-MM-DD)"}
    if save and not (settings.zjut_key or "").strip():
        return {"ok": False, "error": "服务器未配置 ZJUT_KEY,无法加密存储凭据;请先取消保存或配置密钥"}
    try:
        result = await zjut_import.run_import(
            settings.database_path, student_id=sid, password=pw, year=year, term=term, week1_monday=week1)
        await zjut_import.save_config(
            settings.database_path, student_id=sid, password=pw, year=year, term=term,
            week1_monday=week1, save_credentials=save)
    except zjut.ZjutError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}
    result["credentials_saved"] = save
    return result


@router.post("/refresh")
async def refresh(request: Request):
    """用已存凭据重新导入。手动按钮 / Reconciler external_update 都走这里。"""
    creds = await zjut_import.stored_credentials(settings.database_path)
    if not creds:
        return {"ok": False, "error": "没有已保存的凭据,先在设置里导入一次并勾选保存"}
    sid, pw, year, term, week1 = creds
    try:
        return await zjut_import.run_import(
            settings.database_path, student_id=sid, password=pw, year=year, term=term, week1_monday=week1)
    except zjut.ZjutError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


@router.get("/status")
async def status():
    cfg = await zjut_import.get_config(settings.database_path)
    if not cfg:
        return {"configured": False}
    return {
        "configured": True,
        "student_id": cfg.get("student_id"),
        "year": cfg.get("year"),
        "term": cfg.get("term"),
        "week1_monday": cfg.get("week1_monday"),
        "credentials_saved": bool(cfg.get("save_credentials")),
        "last_import_at": cfg.get("last_import_at"),
    }
