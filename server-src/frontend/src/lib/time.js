// ── Shared time utilities ──────────────────────────────────────────────────
// One source of truth for parsing/formatting the backend's mixed ISO strings
// (UTC with Z, UTC bare, explicit offsets). Every component used to roll its
// own; these helpers agree on one rule: no explicit offset → treat as UTC.

const CHINA_TZ = "Asia/Shanghai";

/** Parse a backend timestamp. Bare wall-clock (no Z / offset) is treated as UTC,
 * matching what FastAPI's datetime.utcnow().isoformat() emits. */
export function parseUTC(isoStr) {
  if (!isoStr) return new Date(0);
  const s = /[Z+]/.test(isoStr) ? isoStr : `${isoStr}Z`;
  return new Date(s);
}

/** "刚刚 / N 分钟前 / N 小时前 / N 天前" */
export function relativeTime(isoStr) {
  const diff = Date.now() - parseUTC(isoStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (!Number.isFinite(mins)) return "";
  if (mins < 1) return "刚刚";
  if (mins < 60) return `${mins} 分钟前`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.floor(hours / 24)} 天前`;
}

/** Countdown label: "已到期 / 5min 后 / 3h 后 / 2天后" */
export function timeUntil(isoStr) {
  const diff = parseUTC(isoStr).getTime() - Date.now();
  if (Number.isNaN(diff)) return "";
  if (diff <= 0) return "已到期";
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return `${mins}min 后`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h 后`;
  return `${Math.floor(hours / 24)}天后`;
}

/** Due-date coloring thresholds: overdue / <24h / <72h / calm. */
export function dueTone(isoStr) {
  if (!isoStr) return "text-[var(--text-tertiary)]";
  const diff = new Date(isoStr).getTime() - Date.now();
  if (diff < 0) return "text-red-400";
  if (diff < 24 * 3600 * 1000) return "text-orange-400";
  if (diff < 72 * 3600 * 1000) return "text-yellow-400";
  return "text-[var(--text-tertiary)]";
}

/** "今天 / 昨天 / 6月15日" grouping key in China time. */
export function dayKey(isoStr) {
  if (!isoStr) return "未知日期";
  const d = parseUTC(isoStr);
  if (Number.isNaN(d.getTime())) return "未知日期";
  const fmt = (dd) => dd.toLocaleDateString("en-CA", { timeZone: CHINA_TZ });
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (fmt(d) === fmt(today)) return "今天";
  if (fmt(d) === fmt(yesterday)) return "昨天";
  return d.toLocaleDateString("zh-CN", { month: "long", day: "numeric", timeZone: CHINA_TZ });
}

/** Group an array of {sent_at}-like rows into ordered day groups. */
export function groupByDay(items, tsField = "sent_at") {
  const groups = [];
  const seen = {};
  for (const item of items) {
    const key = dayKey(item[tsField]);
    if (!seen[key]) {
      seen[key] = [];
      groups.push({ label: key, items: seen[key] });
    }
    seen[key].push(item);
  }
  return groups;
}

/** Compact HH:MM in China time. */
export function formatTime(value) {
  if (!value) return "";
  return new Date(value).toLocaleTimeString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone: CHINA_TZ,
  });
}

/** MM-DD HH:mm in China time (log timestamps etc.). */
export function formatShortDateTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}
