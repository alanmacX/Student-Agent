"""浙江工业大学 (zjut) 正方教务 —— 按需登录 + 拉课表/考试。

移植自 jeccj/zf-api 的 ZjutCasAdapter + zjutCas:zjut 走 CAS SSO,**无验证码**,
密码用学校那套自定义 RSA 加密(把密码反转后分块 modPow)。纯 httpx,一次登录
会话内把课表+考试拉完,不长期保存 cookie(会话短命,每次刷新重新登录)。

只产出结构化数据;按周次展开成 server_courses、写考试,都在调用方(import 服务)做。
触发方式:手动 或 Reconciler 的 external_update 信号,绝不定时空跑。
"""
from __future__ import annotations

import html as _html
import math
import re

import httpx

BASE = "http://www.gdjw.zjut.edu.cn"
LOGIN_PAGE = "/jwglxt/xtgl/login_slogin.html"
SSO_ENTRY = "/sso/zfiotlogin"
PUBKEY_PATH = "v2/getPubKey"
AREA_FIVE = "/jwglxt/xtgl/index_cxAreaFive.html?localeKey=zh_CN&gnmkdm=index"
SCHEDULE_PAGE = "/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N253508"
SCHEDULE = "/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N253508"
EXAMS_PAGE = "/jwglxt/kwgl/kscx_cxXsksxxIndex.html?gnmkdm=N358105"
EXAMS = "/jwglxt/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105"
TERM_MAP = {"1": "3", "2": "12", "3": "16"}  # 第1/2/3学期 -> 正方 xqm 码
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


class ZjutError(Exception):
    pass


class ZjutLoginError(ZjutError):
    pass


# ── RSA (1:1 移植自 zjutCas.ts 的 rsaUtilsEncryptString) ───────────────────────

def _normalize_hex(v: str) -> str:
    v = v.strip().lower()
    return v[2:] if v.startswith("0x") else v


def _bigint_to_hex(value: int) -> str:
    digits: list[int] = []
    while value > 0:
        digits.append(value & 0xFFFF)
        value >>= 16
    if not digits:
        digits = [0]
    return "".join(format(d, "04x") for d in reversed(digits))


def _rsa_encrypt(modulus_hex: str, exponent_hex: str, value: str) -> str:
    mod_hex = _normalize_hex(modulus_hex)
    digit_count = math.ceil(len(mod_hex) / 4)
    chunk = 2 * (digit_count - 1)
    if chunk <= 0:
        raise ZjutError("invalid RSA chunk size")
    exponent = int(_normalize_hex(exponent_hex), 16)
    modulus = int(mod_hex, 16)
    chars = [ord(c) for c in value]
    while len(chars) % chunk != 0:
        chars.append(0)
    blocks: list[str] = []
    for i in range(0, len(chars), chunk):
        block = 0
        for off in range(0, chunk, 2):
            first = chars[i + off] if i + off < len(chars) else 0
            second = chars[i + off + 1] if i + off + 1 < len(chars) else 0
            digit = first + (second << 8)
            block += digit << ((off // 2) * 16)
        blocks.append(_bigint_to_hex(pow(block, exponent, modulus)))
    return " ".join(blocks)


def _encrypt_password(password: str, modulus: str, exponent: str) -> str:
    # zjut 先把密码字符串反转再加密
    return _rsa_encrypt(modulus, exponent, password[::-1])


# ── CAS 登录表单解析(正则,够用) ──────────────────────────────────────────────

def _parse_cas_form(html_text: str, page_url: str) -> tuple[str, dict[str, str]]:
    forms = re.findall(r"<form\b[^>]*>.*?</form>", html_text, re.S | re.I)
    target = next((f for f in forms if re.search(r'type=["\']password["\']', f, re.I)), None)
    if not target:
        raise ZjutLoginError("CAS 登录表单未找到(页面结构可能变了)")
    m = re.search(r'<form\b[^>]*\baction=["\']([^"\']*)["\']', target, re.I)
    action = str(httpx.URL(page_url).join(m.group(1))) if (m and m.group(1)) else page_url
    fields: dict[str, str] = {}
    for el in re.findall(r"<(?:input|button)\b[^>]*>", target, re.I):
        nm = re.search(r'\bname=["\']([^"\']+)["\']', el, re.I)
        if not nm:
            continue
        name = nm.group(1)
        vm = re.search(r'\bvalue=["\']([^"\']*)["\']', el, re.I)
        value = _html.unescape(vm.group(1)) if vm else ""
        tm = re.search(r'\btype=["\']([^"\']+)["\']', el, re.I)
        typ = tm.group(1).lower() if tm else ""
        if typ == "hidden" or name == "_eventId" or value:
            fields[name] = value
    fields.setdefault("_eventId", "submit")
    return action, fields


# ── 节次/星期/周次解析(移植自 parserUtils.ts) ────────────────────────────────

def _clean(v) -> str:
    return re.sub(r"\s+", " ", str(v or "").replace(" ", " ")).strip()


def parse_weekday(value: str) -> int | None:
    t = _clean(value).lower()
    table = {"1": 1, "一": 1, "周一": 1, "星期一": 1, "2": 2, "二": 2, "周二": 2, "星期二": 2,
             "3": 3, "三": 3, "周三": 3, "星期三": 3, "4": 4, "四": 4, "周四": 4, "星期四": 4,
             "5": 5, "五": 5, "周五": 5, "星期五": 5, "6": 6, "六": 6, "周六": 6, "星期六": 6,
             "7": 7, "日": 7, "天": 7, "周日": 7, "周天": 7, "星期日": 7, "星期天": 7}
    if t in table:
        return table[t]
    m = re.search(r"[一二三四五六日天]", t)
    return table.get(m.group(0)) if m else None


def parse_sections(value: str) -> tuple[int, int] | None:
    m = re.search(r"\d+\s*(?:[-~至]\s*\d+)?", _clean(value))
    if not m:
        return None
    parts = [int(p) for p in re.split(r"[-~至]", m.group(0)) if p.strip().isdigit()]
    if not parts:
        return None
    start = parts[0]
    end = parts[1] if len(parts) > 1 else start
    return (start, end) if start and end else None


def parse_weeks(value: str) -> list[int]:
    text = _clean(value)
    segments = [s.strip() for s in re.split(r"[,，;；、]", text) if s.strip()] or [text]
    weeks: set[int] = set()
    for seg in segments:
        odd_only = "单" in seg and "双" not in seg
        even_only = "双" in seg and "单" not in seg
        for match in re.findall(r"\d+\s*(?:[-~至]\s*\d+)?", seg):
            parts = [int(p) for p in re.split(r"[-~至]", match) if p.strip().isdigit()]
            if not parts:
                continue
            start = parts[0]
            end = parts[1] if len(parts) > 1 else start
            for w in range(start, end + 1):
                if odd_only and w % 2 == 0:
                    continue
                if even_only and w % 2 != 0:
                    continue
                weeks.add(w)
    return sorted(weeks)


def _get(row: dict, keys: list[str]) -> str:
    for k in keys:
        if k in row and row[k] not in (None, ""):
            return _clean(row[k])
    return ""


def _find_rows(payload, score_fn) -> list[dict]:
    """正方有时把数组藏在不同 key 下;直接取 kbList,否则取打分最高的对象数组。"""
    if isinstance(payload, dict) and isinstance(payload.get("kbList"), list):
        return [r for r in payload["kbList"] if isinstance(r, dict)]
    best: tuple[float, list[dict]] = (0, [])
    def walk(v):
        nonlocal best
        if isinstance(v, list):
            objs = [x for x in v if isinstance(x, dict)]
            if objs:
                s = sum(score_fn(r) for r in objs[:5])
                if s > best[0]:
                    best = (s, objs)
            for x in v:
                walk(x)
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)
    walk(payload)
    return best[1] if best[0] > 0 else []


def parse_schedule(payload) -> list[dict]:
    def score(r):
        return ((4 if _get(r, ["kcmc", "courseName"]) else 0)
                + (2 if _get(r, ["xqj", "weekday"]) else 0)
                + (2 if _get(r, ["jcs", "jc", "section"]) else 0)
                + (1 if _get(r, ["zcd", "weeks"]) else 0))
    out: list[dict] = []
    for row in _find_rows(payload, score):
        name = _get(row, ["kcmc", "courseName", "课程名称"])
        weekday = parse_weekday(_get(row, ["xqj", "skxq", "weekday"]))
        sections = parse_sections(_get(row, ["jcs", "jc", "skjc", "section"]))
        weeks = parse_weeks(_get(row, ["zcd", "skzc", "weeks"]))
        if not name or weekday is None or not sections:
            continue
        out.append({
            "course": name,
            "teacher": _get(row, ["xm", "jsxm", "teacher"]),
            "weekday": weekday,
            "start_section": sections[0],
            "end_section": sections[1],
            "weeks": weeks,
            "classroom": _get(row, ["cdmc", "jxcdmc", "classroom"]),
            "campus": _get(row, ["xqmc", "campus"]),
        })
    return out


def parse_exams(payload) -> list[dict]:
    def score(r):
        return ((3 if _get(r, ["kcmc", "courseName"]) else 0)
                + (3 if _get(r, ["kssj", "ksrq", "examTime", "考试时间"]) else 0))
    out: list[dict] = []
    for row in _find_rows(payload, score):
        name = _get(row, ["kcmc", "courseName", "课程名称"])
        when = _get(row, ["kssj", "examTime", "考试时间"])
        if not name or not when:
            continue
        out.append({
            "course": name,
            "time_raw": when,                                   # 如 "2026-06-20 (14:00-16:00)"
            "location": _get(row, ["cdmc", "jsmc", "examRoom", "考场"]),
            "seat": _get(row, ["zwxh", "座位号"]),
            "exam_name": _get(row, ["ksmc", "examName"]),
        })
    return out


# ── 登录 + 拉取(一次会话) ────────────────────────────────────────────────────

async def _login(client: httpx.AsyncClient, student_id: str, password: str) -> None:
    await client.get(BASE + LOGIN_PAGE)
    cas_page = await client.get(BASE + SSO_ENTRY)
    action, fields = _parse_cas_form(cas_page.text, str(cas_page.url))
    pk_url = str(httpx.URL(action).join(PUBKEY_PATH))
    pk = (await client.get(pk_url, headers={"accept": "application/json,*/*"})).json()
    if not pk.get("modulus") or not pk.get("exponent"):
        raise ZjutLoginError("拿不到 CAS RSA 公钥")
    fields["username"] = student_id
    fields["password"] = _encrypt_password(password, str(pk["modulus"]), str(pk["exponent"]))
    res = await client.post(
        action, data=fields,
        headers={"content-type": "application/x-www-form-urlencoded;charset=UTF-8"},
    )
    if res.status_code >= 400 or re.search(r"/cas/login", str(res.url), re.I):
        raise ZjutLoginError("正方登录失败:账号密码错误、或被风控/需验证")


async def _post_query(client: httpx.AsyncClient, warm: str, query: str, year: str, term: str):
    await client.get(BASE + warm)
    r = await client.post(
        BASE + query,
        data={"xnm": year, "xqm": TERM_MAP.get(term, term)},
        headers={"accept": "application/json,*/*",
                 "content-type": "application/x-www-form-urlencoded;charset=UTF-8"},
    )
    try:
        return r.json()
    except Exception as e:
        raise ZjutError(f"正方返回非 JSON(会话可能失效):{str(e)}")


# 校历头部:如 "2025-2026学年2学期(2026-03-02至2026-07-05)"
_SEM_RE = re.compile(r"(\d{4})-\d{4}学年(\d)学期\((\d{4}-\d{2}-\d{2})至(\d{4}-\d{2}-\d{2})\)")


async def _fetch_semester(client: httpx.AsyncClient) -> dict | None:
    """从校历区块自动读出当前学年/学期/开学日(第1周周一),用户无需手填。"""
    r = await client.post(BASE + AREA_FIVE, headers={"accept": "*/*"})
    m = _SEM_RE.search(r.text)
    if not m:
        return None
    year, term, start, end = m.group(1), m.group(2), m.group(3), m.group(4)
    return {
        "year": year, "term": term,
        "week1_monday": start,           # 学期起始日即第1周周一(正方按周一起算)
        "start": start, "end": end,
        "label": f"{year}-{int(year) + 1}学年第{term}学期",
    }


async def fetch_timetable_and_exams(student_id: str, password: str,
                                    year: str = "", term: str = "") -> dict:
    """登录一次。year/term 留空则自动检测当前学期。返回 {semester, courses, exams}。"""
    async with httpx.AsyncClient(
        follow_redirects=True, timeout=25.0, headers={"user-agent": UA, "accept-language": "zh-CN"}
    ) as client:
        await _login(client, student_id, password)
        semester = await _fetch_semester(client)
        use_year = year or (semester["year"] if semester else "")
        use_term = term or (semester["term"] if semester else "")
        if not use_year or not use_term:
            raise ZjutError("拿不到当前学期信息,且未手动指定 year/term")
        sched_json = await _post_query(client, SCHEDULE_PAGE, SCHEDULE, use_year, use_term)
        exam_json = await _post_query(client, EXAMS_PAGE, EXAMS, use_year, use_term)
        return {
            "semester": semester,
            "courses": parse_schedule(sched_json),
            "exams": parse_exams(exam_json),
        }
