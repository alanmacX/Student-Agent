import { useState } from "react";
import { Download, Upload, AlertTriangle } from "lucide-react";

export default function DataPanel() {
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState(null);

  const handleExport = () => {
    window.location.href = "/api/data/export";
  };

  const handleImport = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setImporting(true);
    setImportResult(null);
    try {
      const text = await file.text();
      const data = JSON.parse(text);
      const r = await fetch("/api/data/import", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      });
      const result = await r.json();
      setImportResult(result);
    } catch (err) {
      setImportResult({ error: err.message });
    } finally {
      setImporting(false);
      e.target.value = "";
    }
  };

  return (
    <div className="stagger max-w-xl space-y-5">
      <div>
        <h2 className="text-lg font-semibold text-white">数据管理</h2>
        <p className="mt-1 text-sm text-[var(--text-tertiary)]">
          导出备份用于服务器迁移，或从备份文件恢复数据。
        </p>
      </div>

      {/* Export */}
      <div className="ui-card p-5 space-y-3">
        <h3 className="text-sm font-semibold text-white">导出数据</h3>
        <p className="text-xs text-[var(--text-tertiary)]">
          导出所有对话、课程、提醒、Memory 等数据为 JSON 文件。不含设备推送订阅和学习通登录 Cookie。
        </p>
        <button
          onClick={handleExport}
          className="flex items-center gap-2 rounded-2xl bg-[var(--accent)] px-4 py-2.5 text-sm font-semibold text-white hover:bg-[var(--accent-strong)]"
        >
          <Download size={16} />
          导出 JSON 备份
        </button>
      </div>

      {/* Import */}
      <div className="ui-card p-5 space-y-3">
        <h3 className="text-sm font-semibold text-white">导入数据</h3>
        <div className="flex items-start gap-2 rounded-2xl border border-orange-500/30 bg-orange-500/10 p-3">
          <AlertTriangle size={16} className="mt-0.5 shrink-0 text-orange-400" />
          <p className="text-xs text-orange-300">
            导入使用 INSERT OR IGNORE，不会覆盖已存在的记录。建议在新服务器的空数据库上导入。
          </p>
        </div>
        <label className="flex cursor-pointer items-center gap-2 rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-4 py-2.5 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]">
          <Upload size={16} />
          {importing ? "导入中..." : "选择备份文件"}
          <input
            type="file"
            accept=".json"
            className="hidden"
            onChange={handleImport}
            disabled={importing}
          />
        </label>
        {importResult && (
          <div className="rounded-2xl border border-[var(--border)] bg-[var(--deep-bg)] p-3 text-xs text-[var(--text-secondary)] font-mono overflow-x-auto">
            {importResult.error ? (
              <p className="text-red-400">{importResult.error}</p>
            ) : (
              <pre>{JSON.stringify(importResult.results, null, 2)}</pre>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
