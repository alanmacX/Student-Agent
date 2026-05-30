import { useState } from "react";
import { X, Upload, AlertCircle, CheckCircle2 } from "lucide-react";
import { importCourses } from "../../api/schedule";

const EXAMPLE = [
  { name: "高等数学", day: 1, periods: [1, 2], location: "A101", teacher: "张老师", weeks: [1, 16] },
  { name: "大学英语", day: 2, periods: [3, 4], location: "B202", teacher: "李老师", weeks: [1, 16] },
  { name: "线性代数", day: 3, periods: [5, 6], location: "C303", weeks: [1, 8] },
];

const PERIOD_LABEL = {
  1: "08:00", 2: "08:55", 3: "10:00", 4: "10:55",
  5: "14:00", 6: "14:55", 7: "16:00", 8: "16:55",
  9: "19:00", 10: "19:55",
};
const PERIOD_END_LABEL = {
  1: "08:45", 2: "09:40", 3: "10:45", 4: "11:40",
  5: "14:45", 6: "15:40", 7: "16:45", 8: "17:40",
  9: "19:45", 10: "20:40",
};
const DAY_LABELS = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"];

export default function ImportModal({ onClose, onImported }) {
  const [semesterStart, setSemesterStart] = useState("");
  const [jsonText, setJsonText] = useState(JSON.stringify(EXAMPLE, null, 2));
  const [status, setStatus] = useState(null); // null | "loading" | "ok" | "error"
  const [errorMsg, setErrorMsg] = useState("");

  let parsed = null;
  let parseError = "";
  try {
    parsed = JSON.parse(jsonText);
    if (!Array.isArray(parsed)) parseError = "必须是数组 [...]";
  } catch (e) {
    parseError = e.message;
  }

  const handleImport = async () => {
    if (!semesterStart) { setErrorMsg("请输入学期起始日期"); return; }
    if (parseError || !parsed) { setErrorMsg(parseError || "JSON 解析失败"); return; }
    setStatus("loading");
    setErrorMsg("");
    try {
      const res = await importCourses(semesterStart, parsed);
      if (res.ok) {
        setStatus("ok");
        onImported?.();
      } else {
        setStatus("error");
        setErrorMsg(res.error || "导入失败");
      }
    } catch (e) {
      setStatus("error");
      setErrorMsg(e.message);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-[var(--overlay-bg)] backdrop-blur-sm sm:items-center">
      <div className="flex max-h-[90dvh] w-full max-w-lg flex-col rounded-t-3xl bg-[var(--panel-bg)] shadow-2xl sm:rounded-2xl">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-[var(--border)] px-4 py-3">
          <div>
            <p className="text-sm font-semibold text-[var(--text-primary)]">导入课程表</p>
            <p className="text-xs text-[var(--text-tertiary)]">将每周课表转为日历事件</p>
          </div>
          <button
            onClick={onClose}
            className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            <X size={16} />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Semester start */}
          <div>
            <label className="mb-1 block text-xs font-medium text-[var(--text-secondary)]">
              学期第 1 周的周一日期
            </label>
            <input
              type="date"
              value={semesterStart}
              onChange={e => setSemesterStart(e.target.value)}
              className="w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm text-[var(--text-primary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
            />
          </div>

          {/* JSON input */}
          <div>
            <label className="mb-1 block text-xs font-medium text-[var(--text-secondary)]">
              课程数据（JSON 数组）
            </label>
            <textarea
              value={jsonText}
              onChange={e => setJsonText(e.target.value)}
              rows={12}
              spellCheck={false}
              className="w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 font-mono text-xs text-[var(--text-primary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
              style={{ resize: "vertical" }}
            />
            {parseError && (
              <p className="mt-1 text-xs text-red-400">⚠ {parseError}</p>
            )}
          </div>

          {/* Field guide */}
          <div className="rounded-xl bg-[var(--surface)] p-3 text-xs text-[var(--text-tertiary)] space-y-0.5">
            <p className="font-semibold text-[var(--text-secondary)] mb-1">字段说明</p>
            <p><code className="text-[var(--accent-soft)]">day</code>：1=周一 … 7=周日</p>
            <p><code className="text-[var(--accent-soft)]">periods</code>：[起始节, 结束节]，节次→时间见下</p>
            <p><code className="text-[var(--accent-soft)]">weeks</code>：[起始周, 结束周]，默认 [1, 16]</p>
            <p className="mt-1 font-semibold text-[var(--text-secondary)]">节次时间</p>
            {[1,3,5,7,9].map(p => (
              <p key={p}>{p}-{p+1}节：{PERIOD_LABEL[p]} – {PERIOD_END_LABEL[p+1]}</p>
            ))}
          </div>

          {/* Preview */}
          {parsed && !parseError && (
            <div className="rounded-xl bg-[var(--surface)] p-3">
              <p className="text-xs font-semibold text-[var(--text-secondary)] mb-2">预览（{parsed.length} 门课）</p>
              <div className="space-y-1">
                {parsed.slice(0, 6).map((c, i) => (
                  <div key={i} className="flex items-center gap-2 text-xs text-[var(--text-secondary)]">
                    <span className="shrink-0 rounded bg-[var(--accent)] px-1.5 py-0.5 text-[10px] text-white font-medium">
                      {DAY_LABELS[c.day] || `Day${c.day}`}
                    </span>
                    <span className="font-medium text-[var(--text-primary)]">{c.name}</span>
                    {c.location && <span className="text-[var(--text-tertiary)]">{c.location}</span>}
                    <span className="ml-auto text-[var(--text-tertiary)]">
                      第{(c.weeks||[1,16])[0]}-{(c.weeks||[1,16])[1]}周
                    </span>
                  </div>
                ))}
                {parsed.length > 6 && (
                  <p className="text-xs text-[var(--text-tertiary)]">…另 {parsed.length - 6} 门</p>
                )}
              </div>
            </div>
          )}

          {/* Error / success */}
          {status === "error" && errorMsg && (
            <div className="flex items-center gap-2 rounded-xl bg-red-500/10 px-3 py-2 text-sm text-red-400">
              <AlertCircle size={14} /> {errorMsg}
            </div>
          )}
          {status === "ok" && (
            <div className="flex items-center gap-2 rounded-xl bg-green-500/10 px-3 py-2 text-sm text-green-400">
              <CheckCircle2 size={14} /> 导入成功！
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 border-t border-[var(--border)] px-4 py-3">
          <button
            onClick={onClose}
            className="rounded-xl px-4 py-2 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            关闭
          </button>
          <button
            onClick={handleImport}
            disabled={status === "loading" || !!parseError || !semesterStart}
            className="flex items-center gap-2 rounded-xl bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white shadow transition hover:bg-[var(--accent-strong)] disabled:opacity-50"
          >
            <Upload size={14} />
            {status === "loading" ? "导入中…" : "确认导入"}
          </button>
        </div>
      </div>
    </div>
  );
}
