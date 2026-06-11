"""ZJUT 正方教务接入端点(初版:只做登录验证 / 预览,不落库)。

/api/zjut/probe —— 用真实学号密码登录一次,返回解析后的课表+考试预览。
用于在搭建"加密存储 + 课表展开 + 界面"之前,先验证对真实服务器的登录可行。
不存储凭据、不写库、不在日志里打印密码。令牌保护(同全站中间件)。
"""
from __future__ import annotations

from fastapi import APIRouter, Request

from app.services import zjut

router = APIRouter(prefix="/api/zjut", tags=["zjut"])


@router.post("/probe")
async def probe(request: Request):
    body = await request.json()
    student_id = (body.get("student_id") or "").strip()
    password = body.get("password") or ""
    year = (body.get("year") or "").strip()
    term = (body.get("term") or "").strip()
    if not student_id or not password or not year or not term:
        return {"ok": False, "error": "需要 student_id / password / year(如2025) / term(1|2|3)"}
    try:
        data = await zjut.fetch_timetable_and_exams(student_id, password, year, term)
    except zjut.ZjutError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"未知错误: {type(e).__name__}: {e}"}
    courses = data["courses"]
    exams = data["exams"]
    return {
        "ok": True,
        "course_rows": len(courses),
        "exam_rows": len(exams),
        "courses_preview": courses[:8],
        "exams_preview": exams[:8],
    }
