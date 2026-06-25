import { useEffect, useState } from "react";
import { GraduationCap, RefreshCw, Loader2, CheckCircle2, ShieldCheck } from "lucide-react";
import { apiFetch } from "../../api/client";

export default function ZjutSettings() {
  const [status, setStatus] = useState(null);
  const [studentId, setStudentId] = useState("");
  const [password, setPassword] = useState("");
  const [save, setSave] = useState(true);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null); // {ok, text}

  const loadStatus = async () => {
    try { setStatus(await apiFetch("/api/zjut/status")); } catch { /* ignore */ }
  };
  useEffect(() => { loadStatus(); }, []);

  const doImport = async () => {
    if (!studentId.trim() || !password) return;
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch("/api/zjut/import", {
        method: "POST",
        body: JSON.stringify({ student_id: studentId.trim(), password, save_credentials: save }),
      });
      if (r.ok) {
        const terms = r.prefetched_terms?.length ? ` · 已预抓 ${r.prefetched_terms.length} 个时期` : "";
        setMsg({ ok: true, text: `导入成功 · ${r.semester} · ${r.course_sessions_written} 节课 / ${r.exams_written} 场考试${terms}` });
        setPassword("");
        loadStatus();
      } else {
        setMsg({ ok: false, text: r.error || "导入失败" });
      }
    } catch (e) {
      setMsg({ ok: false, text: String(e.message || e) });
    } finally { setBusy(false); }
  };

  const doRefresh = async () => {
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch("/api/zjut/refresh", { method: "POST" });
      const terms = r.prefetched_terms?.length ? ` · 已预抓 ${r.prefetched_terms.length} 个时期` : "";
      setMsg(r.ok
        ? { ok: true, text: `已刷新 · ${r.semester} · ${r.course_sessions_written} 节课 / ${r.exams_written} 场考试${terms}` }
        : { ok: false, text: r.error || "刷新失败" });
      loadStatus();
    } catch (e) {
      setMsg({ ok: false, text: String(e.message || e) });
    } finally { setBusy(false); }
  };

  const fmt = (iso) => iso ? new Date(iso).toLocaleString("zh-CN", { hour12: false }) : "—";

  return (
    <div className="mx-auto max-w-xl space-y-5">
      <div className="flex items-center gap-2">
        <GraduationCap size={18} className="text-[var(--accent)]" />
        <h2 className="text-base font-semibold text-white">正方教务（浙工大）</h2>
      </div>

      {status?.configured && (
        <div className="surface-card p-4 space-y-2">
          <div className="flex items-center gap-2 text-sm text-[var(--text-secondary)]">
            <CheckCircle2 size={15} className="text-green-400" />
            <span>{status.semester_label || "已配置"}</span>
            {status.credentials_saved && (
              <span className="rounded-full bg-[var(--accent)]/15 px-2 py-0.5 text-[11px] text-[var(--accent-soft)]">已保存凭据</span>
            )}
          </div>
          <p className="text-xs text-[var(--text-tertiary)]">学号 {status.student_id} · 上次导入 {fmt(status.last_import_at)}</p>
          {!!status.terms?.length && (
            <div className="space-y-1 rounded-xl bg-[var(--surface)]/70 p-2">
              {status.terms.map((term) => (
                <div key={term.termKey} className="flex items-center justify-between gap-2 text-[11px] text-[var(--text-secondary)]">
                  <span className="truncate">{term.semesterLabel}</span>
                  <span className="shrink-0 text-[var(--text-tertiary)]">
                    {term.startDate || term.week1Monday} 起 · {term.coursesCount || 0} 节
                  </span>
                </div>
              ))}
            </div>
          )}
          {status.credentials_saved && (
            <button onClick={doRefresh} disabled={busy}
              className="mt-1 inline-flex items-center gap-2 rounded-xl bg-[var(--hover-bg)] px-3 py-2 text-sm text-white hover:bg-[var(--hover-bg-strong)] disabled:opacity-40">
              {busy ? <Loader2 size={15} className="animate-spin" /> : <RefreshCw size={15} />}立即刷新
            </button>
          )}
        </div>
      )}

      <div className="surface-card p-4 space-y-3">
        <p className="text-sm font-medium text-white">{status?.configured ? "重新导入 / 换账号" : "导入课表 + 考试"}</p>
        <input value={studentId} onChange={(e) => setStudentId(e.target.value)} placeholder="学号"
          className="glass-input w-full rounded-xl px-3 py-2.5 text-sm" autoComplete="off" />
        <input value={password} onChange={(e) => setPassword(e.target.value)} type="password" placeholder="教务系统密码"
          className="glass-input w-full rounded-xl px-3 py-2.5 text-sm" autoComplete="off"
          onKeyDown={(e) => e.key === "Enter" && doImport()} />
        <label className="flex items-center gap-2 text-xs text-[var(--text-secondary)]">
          <input type="checkbox" checked={save} onChange={(e) => setSave(e.target.checked)} className="accent-[var(--accent)]" />
          保存密码（加密存储，用于以后一键/事件刷新）
        </label>
        <button onClick={doImport} disabled={busy || !studentId.trim() || !password}
          className="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-[var(--accent)] py-2.5 text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-40">
          {busy ? <Loader2 size={16} className="animate-spin" /> : <GraduationCap size={16} />}
          {busy ? "登录正方中…" : "导入"}
        </button>
        {msg && (
          <p className={`text-xs ${msg.ok ? "text-green-400" : "text-red-400"}`}>{msg.text}</p>
        )}
        <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-[var(--text-tertiary)]">
          <ShieldCheck size={13} className="mt-0.5 shrink-0" />
          学年/学期/开学日会自动从教务和校历推断，并预抓可确定的短学期；密码用 AES-GCM 加密存储、不进日志，仅用于登录正方拉取课表。
        </p>
      </div>
    </div>
  );
}
