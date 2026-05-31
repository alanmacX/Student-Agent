import { useState, useEffect, useCallback } from "react";
import {
  RefreshCw, Loader2, CheckCircle2, AlertCircle, Bot,
  Cpu, HardDrive, Clock, Terminal, RotateCw, FileText, Settings,
} from "lucide-react";
import { apiFetch } from "../../api/client";

function fmtTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("zh-CN", {
    month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
}

function fmtAge(iso) {
  if (!iso) return "—";
  const s = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${s}s 前`;
  if (s < 3600) return `${Math.floor(s / 60)}m 前`;
  return `${Math.floor(s / 3600)}h 前`;
}

function StatCard({ icon, label, value, color = "text-blue-400" }) {
  return (
    <div className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
      <div className="flex items-center gap-1.5 mb-1">
        {icon}
        <span className="text-[11px] text-[var(--text-tertiary)]">{label}</span>
      </div>
      <p className="text-sm font-semibold text-white">{value}</p>
    </div>
  );
}

function ContainerRow({ name, data, onRestart, restarting }) {
  const running = data?.running;
  return (
    <div className={`rounded-xl border p-3 ${
      running ? "border-green-500/20 bg-green-500/5" : "border-red-500/20 bg-red-500/5"
    }`}>
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-2">
          {running
            ? <CheckCircle2 size={15} className="text-green-400" />
            : <AlertCircle size={15} className="text-red-400" />
          }
          <span className="text-sm font-medium text-white">{name}</span>
        </div>
        <button
          onClick={() => onRestart(name === "core" ? "core" : "napcat")}
          disabled={restarting}
          className="flex items-center gap-1 rounded-lg bg-[var(--hover-bg)] px-2.5 py-1 text-[11px] text-[var(--text-secondary)] hover:text-white transition-colors disabled:opacity-50"
        >
          {restarting ? <Loader2 size={11} className="animate-spin" /> : <RotateCw size={11} />}
          重启
        </button>
      </div>
      <div className="grid grid-cols-2 gap-2 text-xs">
        <div className="flex items-center gap-1.5 text-[var(--text-secondary)]">
          <Cpu size={11} className="text-orange-400" />
          <span>CPU {data?.cpu_percent?.toFixed(1) ?? 0}%</span>
        </div>
        <div className="flex items-center gap-1.5 text-[var(--text-secondary)]">
          <HardDrive size={11} className="text-purple-400" />
          <span>RAM {data?.mem_percent?.toFixed(1) ?? 0}%</span>
        </div>
      </div>
      {data?.mem_usage && (
        <p className="mt-1 text-[10px] text-[var(--text-tertiary)]">{data.mem_usage}</p>
      )}
      {data?.api_alive !== undefined && (
        <div className="mt-1.5 flex items-center gap-1.5 text-xs">
          <div className={`h-1.5 w-1.5 rounded-full ${data.api_alive ? "bg-green-400" : "bg-red-400"}`} />
          <span className="text-[var(--text-tertiary)]">
            API {data.api_alive ? "可达" : "不可达"}
          </span>
        </div>
      )}
    </div>
  );
}

function LogViewer({ logs, loading }) {
  if (loading) return <div className="py-8 text-center"><Loader2 size={20} className="mx-auto animate-spin text-[var(--text-tertiary)]" /></div>;
  if (!logs) return null;
  return (
    <pre className="max-h-80 overflow-auto rounded-xl bg-[var(--deep-bg)] p-3 text-[11px] text-[var(--text-secondary)] leading-5 whitespace-pre-wrap break-all">
      {logs || "(empty)"}
    </pre>
  );
}

function HealthTimeline({ checks }) {
  if (!checks?.length) return null;
  const recent = checks.slice(0, 12).reverse();
  return (
    <div className="space-y-1.5">
      <p className="text-xs font-medium text-[var(--text-tertiary)] uppercase tracking-wider">最近检查</p>
      <div className="flex gap-1">
        {recent.map((c, i) => {
          const ok = c.core_running && c.napcat_running && c.napcat_alive;
          return (
            <div
              key={c.id || i}
              className={`h-6 flex-1 rounded ${ok ? "bg-green-500/40" : "bg-red-500/40"}`}
              title={`${fmtTime(c.checked_at)}\n${c.error || "OK"}`}
            />
          );
        })}
      </div>
      <div className="flex justify-between text-[10px] text-[var(--text-tertiary)]">
        <span>{fmtTime(recent[0]?.checked_at)}</span>
        <span>{fmtTime(recent[recent.length - 1]?.checked_at)}</span>
      </div>
    </div>
  );
}

export default function MaiMBotStatus() {
  const [tab, setTab] = useState("status");
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [restarting, setRestarting] = useState(null);
  const [logs, setLogs] = useState(null);
  const [logsLoading, setLogsLoading] = useState(false);
  const [logContainer, setLogContainer] = useState("core");
  const [config, setConfig] = useState(null);
  const [configLoading, setConfigLoading] = useState(false);
  const [enabled, setEnabled] = useState(false);
  const [savingEnabled, setSavingEnabled] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const s = await apiFetch("/api/maimbot/status");
      setStatus(s);
    } catch (_) {}
    finally { setLoading(false); }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  // Load enabled setting
  useEffect(() => {
    apiFetch("/api/settings/maimbot_enabled")
      .then(r => setEnabled(r.value === "1" || r.value === true))
      .catch(() => {});
  }, []);

  const toggleEnabled = async () => {
    setSavingEnabled(true);
    try {
      const newVal = !enabled;
      await apiFetch("/api/settings/maimbot_enabled", {
        method: "PUT",
        body: JSON.stringify({ value: newVal ? "1" : "0" }),
      });
      setEnabled(newVal);
    } catch (_) {}
    finally { setSavingEnabled(false); }
  };

  const handleRestart = async (container) => {
    setRestarting(container);
    try {
      await apiFetch(`/api/maimbot/restart?container=${container}`, { method: "POST" });
      setTimeout(refresh, 3000);
    } catch (_) {}
    finally { setRestarting(null); }
  };

  const loadLogs = async (container) => {
    setLogContainer(container);
    setLogsLoading(true);
    try {
      const r = await apiFetch(`/api/maimbot/logs?container=${container}&lines=100`);
      setLogs(r.logs);
    } catch (_) { setLogs("(failed to load)"); }
    finally { setLogsLoading(false); }
  };

  const loadConfig = async () => {
    setConfigLoading(true);
    try {
      const r = await apiFetch("/api/maimbot/config");
      setConfig(r);
    } catch (_) {}
    finally { setConfigLoading(false); }
  };

  useEffect(() => {
    if (tab === "logs") loadLogs(logContainer);
    if (tab === "config" && !config) loadConfig();
  }, [tab]); // eslint-disable-line react-hooks/exhaustive-deps

  if (loading) {
    return (
      <div className="max-w-md space-y-4">
        <h2 className="text-lg font-semibold text-white">MaiMBot</h2>
        <div className="py-12 text-center">
          <Loader2 size={24} className="mx-auto animate-spin text-[var(--text-tertiary)]" />
        </div>
      </div>
    );
  }

  const healthy = status?.healthy;

  return (
    <div className="max-w-md space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-white">MaiMBot</h2>
        <button
          onClick={toggleEnabled}
          disabled={savingEnabled}
          className={`flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium transition-all ${
            enabled
              ? "bg-green-500/20 text-green-300 ring-1 ring-green-500/30"
              : "bg-[var(--hover-bg)] text-[var(--text-tertiary)]"
          }`}
        >
          {savingEnabled ? <Loader2 size={11} className="animate-spin" /> : null}
          {enabled ? "监控中" : "已关闭"}
        </button>
      </div>

      {/* Tab bar */}
      <div className="flex gap-1 rounded-xl bg-[var(--deep-bg)] p-1">
        {[
          ["status", "状态", <Clock size={13} />],
          ["logs", "日志", <Terminal size={13} />],
          ["config", "配置", <Settings size={13} />],
        ].map(([id, label, icon]) => (
          <button key={id} onClick={() => setTab(id)}
            className={`flex flex-1 items-center justify-center gap-1.5 rounded-lg py-2 text-xs font-medium transition-all ${
              tab === id ? "bg-[var(--accent)] text-white" : "text-[var(--text-secondary)] hover:text-white"
            }`}>
            {icon}{label}
          </button>
        ))}
      </div>

      {tab === "status" && (
        <div className="space-y-4">
          {/* Overall health banner */}
          <div className={`rounded-2xl border p-4 ${
            healthy ? "border-green-500/30 bg-green-500/10" : "border-red-500/30 bg-red-500/10"
          }`}>
            <div className="flex items-center gap-3">
              {healthy
                ? <CheckCircle2 size={20} className="shrink-0 text-green-400" />
                : <AlertCircle size={20} className="shrink-0 text-red-400" />
              }
              <div>
                <p className={`text-sm font-medium ${healthy ? "text-green-300" : "text-red-300"}`}>
                  {healthy ? "全部正常" : "存在异常"}
                </p>
                <p className="text-xs text-[var(--text-tertiary)]">
                  上次检查: {fmtAge(status?.checked_at)}
                </p>
              </div>
            </div>
          </div>

          {/* Container cards */}
          <div className="space-y-2">
            <ContainerRow name="core" data={status?.core} onRestart={handleRestart} restarting={restarting} />
            <ContainerRow name="napcat" data={status?.napcat} onRestart={handleRestart} restarting={restarting} />
          </div>

          {/* Health timeline */}
          <HealthTimeline checks={status?.recent_checks} />

          {/* Error count */}
          {status?.error_count_1h > 0 && (
            <div className="flex items-center gap-2 rounded-xl bg-amber-500/10 border border-amber-500/20 px-3 py-2 text-xs text-amber-300">
              <AlertCircle size={13} />
              最近 1 小时有 {status.error_count_1h} 次异常
            </div>
          )}

          <button onClick={refresh}
            className="flex w-full items-center justify-center gap-2 rounded-xl bg-[var(--hover-bg)] py-2.5 text-xs text-[var(--text-secondary)] hover:text-white transition-colors">
            <RefreshCw size={12} /> 刷新状态
          </button>
        </div>
      )}

      {tab === "logs" && (
        <div className="space-y-3">
          <div className="flex gap-1 rounded-xl bg-[var(--deep-bg)] p-1">
            {["core", "napcat"].map(c => (
              <button key={c} onClick={() => { setLogContainer(c); loadLogs(c); }}
                className={`flex flex-1 items-center justify-center gap-1.5 rounded-lg py-1.5 text-xs font-medium transition-all ${
                  logContainer === c ? "bg-[var(--accent)] text-white" : "text-[var(--text-secondary)] hover:text-white"
                }`}>
                {c}
              </button>
            ))}
          </div>
          <LogViewer logs={logs} loading={logsLoading} />
        </div>
      )}

      {tab === "config" && (
        <div className="space-y-3">
          {configLoading
            ? <div className="py-8 text-center"><Loader2 size={20} className="mx-auto animate-spin text-[var(--text-tertiary)]" /></div>
            : config?.error
              ? <p className="text-xs text-red-400">{config.error}</p>
              : config?.configs
                ? Object.entries(config.configs).map(([name, content]) => (
                  <div key={name} className="rounded-xl border border-[var(--border)] overflow-hidden">
                    <div className="flex items-center gap-2 bg-[var(--deep-bg)] px-3 py-2 border-b border-[var(--border)]">
                      <FileText size={13} className="text-[var(--accent)]" />
                      <span className="text-xs font-medium text-white">{name}</span>
                    </div>
                    <pre className="max-h-60 overflow-auto p-3 text-[11px] text-[var(--text-secondary)] leading-5 whitespace-pre-wrap">
                      {content}
                    </pre>
                  </div>
                ))
                : <p className="text-xs text-[var(--text-tertiary)]">暂无配置文件</p>
          }
        </div>
      )}
    </div>
  );
}
