import { useState, useEffect, useCallback, useRef } from "react";
import {
  RefreshCw, Loader2, CheckCircle2, AlertCircle, Play,
  MessageSquare, Clock, Filter, Plus, X, ChevronDown, ChevronUp, Info,
  QrCode, Smartphone,
} from "lucide-react";
import { apiFetch } from "../../api/client";

function fmtAge(s) {
  if (s < 0) return "—";
  if (s < 60) return `${s}s 前`;
  if (s < 3600) return `${Math.floor(s / 60)}m 前`;
  return `${Math.floor(s / 3600)}h 前`;
}
function fmtTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}
function StatCard({ icon, label, value }) {
  return (
    <div className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
      <div className="flex items-center gap-1.5 mb-1">{icon}
        <span className="text-[11px] text-[var(--text-tertiary)]">{label}</span>
      </div>
      <p className="text-sm font-semibold text-white">{value}</p>
    </div>
  );
}

// ── Status tab ─────────────────────────────────────────────────────────────
// ── QR login panel ────────────────────────────────────────────────────────
function QRLoginPanel({ onLoginDetected }) {
  const [imgSrc, setImgSrc] = useState(null);
  const [qrError, setQrError] = useState(false);
  const [loggedIn, setLoggedIn] = useState(false);
  const refreshRef = useRef(null);
  const pollRef = useRef(null);

  const refreshQR = useCallback(() => {
    // Cache-bust so browser always fetches fresh screenshot
    setImgSrc(`/api/dingtalk/qr-screenshot?t=${Date.now()}`);
  }, []);

  const checkLogin = useCallback(async () => {
    try {
      const res = await apiFetch("/api/dingtalk/login-status");
      if (res.logged_in) {
        setLoggedIn(true);
        clearInterval(refreshRef.current);
        clearInterval(pollRef.current);
        setTimeout(onLoginDetected, 1200);
      }
    } catch (_) {}
  }, [onLoginDetected]);

  useEffect(() => {
    refreshQR();
    refreshRef.current = setInterval(refreshQR, 3000);  // refresh screenshot every 3s
    pollRef.current   = setInterval(checkLogin, 2500);  // poll login every 2.5s
    return () => {
      clearInterval(refreshRef.current);
      clearInterval(pollRef.current);
    };
  }, [refreshQR, checkLogin]);

  if (loggedIn) return (
    <div className="flex flex-col items-center gap-3 py-8">
      <CheckCircle2 size={48} className="text-green-400" />
      <p className="text-sm font-semibold text-green-300">登录成功！</p>
      <p className="text-xs text-[var(--text-tertiary)]">正在刷新状态…</p>
    </div>
  );

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 rounded-xl bg-[var(--deep-bg)] p-3 text-xs text-[var(--text-secondary)]">
        <Smartphone size={13} className="shrink-0 text-[var(--accent)]" />
        <span>用手机钉钉扫描下方二维码完成登录，扫码后自动检测。</span>
      </div>

      <div className="relative overflow-hidden rounded-2xl border border-[var(--border)] bg-[var(--deep-bg)]">
        {imgSrc && !qrError ? (
          <img
            src={imgSrc}
            alt="DingTalk QR"
            className="w-full object-contain"
            style={{ maxHeight: 360 }}
            onError={() => setQrError(true)}
            onLoad={() => setQrError(false)}
          />
        ) : (
          <div className="flex flex-col items-center gap-3 py-12 text-[var(--text-tertiary)]">
            {qrError
              ? <><AlertCircle size={28} className="text-amber-400" /><p className="text-xs">截图服务不可用<br/>请确认 dingtalk-qr.service 已启动</p></>
              : <><Loader2 size={24} className="animate-spin" /><p className="text-xs">加载截图…</p></>
            }
          </div>
        )}
        {/* Subtle refresh indicator */}
        <div className="absolute bottom-2 right-2 flex items-center gap-1 rounded-full bg-black/40 px-2 py-0.5 text-[10px] text-white/60">
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-green-400 animate-pulse" />
          自动刷新
        </div>
      </div>

      <button onClick={refreshQR}
        className="flex w-full items-center justify-center gap-2 rounded-xl bg-[var(--hover-bg)] py-2.5 text-xs text-[var(--text-secondary)] hover:text-white transition-colors">
        <RefreshCw size={12} /> 手动刷新截图
      </button>
    </div>
  );
}

// ── Status tab ─────────────────────────────────────────────────────────────
function StatusTab({ status, loggedIn, onSync, onResume, onRefresh, syncing, resuming, loading, onLoginDetected }) {
  const [showQR, setShowQR] = useState(false);

  if (loading) return <div className="py-12 text-center"><Loader2 size={24} className="mx-auto animate-spin text-[var(--text-tertiary)]" /></div>;

  // Not-logged-in state — show QR panel
  if (!loggedIn) return (
    <div className="space-y-4">
      <div className="flex items-center gap-3 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4">
        <AlertCircle size={20} className="shrink-0 text-amber-400" />
        <div>
          <p className="text-sm font-medium text-amber-300">钉钉未登录</p>
          <p className="text-xs text-[var(--text-tertiary)]">扫码登录后即可开始监听消息</p>
        </div>
      </div>
      <button onClick={() => setShowQR(v => !v)}
        className="flex w-full items-center justify-center gap-2 min-h-11 rounded-2xl bg-[var(--accent)] text-sm font-semibold text-white hover:bg-[var(--accent-strong)] transition-colors">
        <QrCode size={16} />
        {showQR ? "隐藏二维码" : "扫码登录"}
      </button>
      {showQR && <QRLoginPanel onLoginDetected={() => { setShowQR(false); onRefresh(); onLoginDetected?.(); }} />}
    </div>
  );

  const alive = status?.client_alive;
  const stopped = status?.process_status === "stopped";
  const notRunning = status?.process_status === "not_running";

  return (
    <div className="space-y-4">
      <div className={`rounded-2xl border p-4 ${alive ? "border-green-500/30 bg-green-500/10" : "border-amber-500/30 bg-amber-500/10"}`}>
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            {alive ? <CheckCircle2 size={20} className="shrink-0 text-green-400" /> : <AlertCircle size={20} className="shrink-0 text-amber-400" />}
            <div>
              <p className={`text-sm font-medium ${alive ? "text-green-300" : "text-amber-300"}`}>
                {notRunning ? "客户端未运行" : stopped ? "客户端已暂停（需要恢复）" : alive ? "客户端正常运行" : "客户端可能掉线"}
              </p>
              <p className="text-xs text-[var(--text-tertiary)]">WAL 更新：{fmtAge(status?.wal_age_seconds)}</p>
            </div>
          </div>
          {stopped && (
            <button onClick={onResume} disabled={resuming}
              className="flex min-h-9 items-center gap-1.5 rounded-xl bg-amber-500/20 px-3 text-xs text-amber-300 hover:bg-amber-500/30">
              {resuming ? <Loader2 size={12} className="animate-spin" /> : <Play size={12} />} 恢复
            </button>
          )}
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <StatCard icon={<Clock size={14} className="text-blue-400" />} label="上次同步" value={fmtTime(status?.last_sync)} />
        <StatCard icon={<MessageSquare size={14} className="text-purple-400" />} label="总消息" value={`${status?.total_messages ?? 0} 条`} />
        <StatCard icon={<CheckCircle2 size={14} className="text-green-400" />} label="今日 notify" value={`${status?.recent_24h?.notify ?? 0} 条`} />
        <StatCard icon={<MessageSquare size={14} className="text-indigo-400" />} label="今日 interest" value={`${status?.recent_24h?.interest ?? 0} 条`} />
      </div>
      <div className="flex gap-2">
        <button onClick={onSync} disabled={syncing}
          className="flex flex-1 min-h-11 items-center justify-center gap-2 rounded-2xl bg-[var(--accent)] px-4 text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-50">
          {syncing ? <Loader2 size={14} className="animate-spin" /> : <RefreshCw size={14} />} 立即同步
        </button>
        <button onClick={onRefresh}
          className="grid h-11 w-11 place-items-center rounded-2xl bg-[var(--hover-bg)] text-[var(--text-secondary)] hover:bg-[var(--hover-bg-strong)]">
          <RefreshCw size={15} />
        </button>
      </div>
      <p className="text-xs text-[var(--text-tertiary)] leading-5">
        钉钉客户端运行在服务器 Xvfb 虚拟显示器上。同步每 60s 自动触发。消息按 notify / interest / drop 三桶分类，notify 的内容 Agent 可直接读取。
      </p>
    </div>
  );
}

// ── Tag input ──────────────────────────────────────────────────────────────
function TagInput({ items, onAdd, onRemove, placeholder, colorClass = "blue" }) {
  const [val, setVal] = useState("");
  const colors = {
    blue: "bg-blue-500/15 text-blue-300 ring-1 ring-blue-500/25",
    red: "bg-red-500/15 text-red-300 ring-1 ring-red-500/25",
  };
  const submit = () => {
    const v = val.trim();
    if (v && !items.includes(v)) { onAdd(v); setVal(""); }
  };
  return (
    <div className="space-y-2">
      {items.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {items.map(it => (
            <span key={it} className={`flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs ${colors[colorClass]}`}>
              {it}
              <button onClick={() => onRemove(it)} className="opacity-60 hover:opacity-100"><X size={11} /></button>
            </span>
          ))}
        </div>
      )}
      <div className="flex gap-2">
        <input value={val} onChange={e => setVal(e.target.value)}
          onKeyDown={e => { if (e.key === "Enter") { e.preventDefault(); submit(); } }}
          placeholder={placeholder}
          className="flex-1 min-h-9 rounded-xl bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] border border-[var(--border)] focus:outline-none focus:border-[var(--accent)]" />
        <button onClick={submit}
          className="grid h-9 w-9 place-items-center rounded-xl bg-[var(--hover-bg)] text-[var(--text-secondary)] hover:text-white transition-colors">
          <Plus size={15} />
        </button>
      </div>
    </div>
  );
}

// ── Filter tab ─────────────────────────────────────────────────────────────
function FilterTab({ dbConversations, loadingConvs }) {
  const [config, setConfig] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [convExpanded, setConvExpanded] = useState(true);

  useEffect(() => {
    apiFetch("/api/dingtalk/filter-config").then(setConfig).catch(() => {});
  }, []);

  const save = async () => {
    if (!config) return;
    setSaving(true);
    try {
      await apiFetch("/api/dingtalk/filter-config", { method: "PUT", body: JSON.stringify(config) });
      setSaved(true);
      setTimeout(() => setSaved(false), 2500);
    } finally { setSaving(false); }
  };

  const toggleConv = (title) => {
    const list = config.conv_list || [];
    setConfig(c => ({
      ...c,
      conv_list: list.includes(title) ? list.filter(t => t !== title) : [...list, title],
    }));
  };

  if (!config) return <div className="py-8 text-center"><Loader2 size={20} className="mx-auto animate-spin text-[var(--text-tertiary)]" /></div>;

  const modeOptions = [
    { id: "all", label: "全部", desc: "处理所有群消息" },
    { id: "whitelist", label: "白名单", desc: "只处理选定的群" },
    { id: "blacklist", label: "黑名单", desc: "排除选定的群" },
  ];

  return (
    <div className="space-y-5">
      {/* Explanation */}
      <div className="flex gap-2 rounded-xl bg-[var(--deep-bg)] p-3 text-xs text-[var(--text-secondary)] leading-5">
        <Info size={13} className="shrink-0 mt-0.5 text-[var(--accent)]" />
        <span>过滤在 AI 分析前生效，不符合的消息直接丢弃，不消耗 LLM 配额。</span>
      </div>

      {/* Mode selector */}
      <div>
        <p className="mb-2 text-xs font-medium text-[var(--text-tertiary)] uppercase tracking-wider">群对话过滤模式</p>
        <div className="grid grid-cols-3 gap-2">
          {modeOptions.map(({ id, label, desc }) => (
            <button key={id} onClick={() => setConfig(c => ({ ...c, conv_mode: id }))}
              title={desc}
              className={`rounded-xl px-2 py-2.5 text-xs font-medium transition-all ${
                config.conv_mode === id
                  ? "bg-[var(--accent)] text-white"
                  : "bg-[var(--hover-bg)] text-[var(--text-secondary)] hover:text-white"
              }`}>
              {label}
            </button>
          ))}
        </div>
        <p className="mt-1.5 text-xs text-[var(--text-tertiary)]">
          {modeOptions.find(m => m.id === config.conv_mode)?.desc}
        </p>
      </div>

      {/* Conversation list (only when not 'all') */}
      {config.conv_mode !== "all" && (
        <div className="rounded-2xl border border-[var(--border)] overflow-hidden">
          <button onClick={() => setConvExpanded(v => !v)}
            className="flex w-full items-center justify-between px-4 py-3 text-sm font-medium text-white hover:bg-[var(--hover-bg)] transition-colors">
            <span>
              {config.conv_mode === "whitelist" ? "要监听的群" : "要排除的群"}
              {(config.conv_list?.length || 0) > 0 && (
                <span className="ml-2 text-xs text-[var(--accent)]">{config.conv_list.length} 个已选</span>
              )}
            </span>
            {convExpanded ? <ChevronUp size={15} /> : <ChevronDown size={15} />}
          </button>

          {convExpanded && (
            <div className="border-t border-[var(--border)] p-3 space-y-3">
              {/* Conversations from DB */}
              {loadingConvs
                ? <div className="py-4 text-center"><Loader2 size={16} className="mx-auto animate-spin text-[var(--text-tertiary)]" /></div>
                : dbConversations.length > 0
                  ? (
                    <div className="space-y-1 max-h-52 overflow-y-auto pr-1">
                      {dbConversations.map(c => {
                        const selected = (config.conv_list || []).includes(c.title);
                        return (
                          <label key={c.title}
                            className={`flex items-center gap-3 rounded-xl px-3 py-2 cursor-pointer transition-colors ${
                              selected ? "bg-[var(--accent)]/15" : "hover:bg-[var(--hover-bg)]"
                            }`}>
                            <input type="checkbox" checked={selected} onChange={() => toggleConv(c.title)}
                              className="rounded accent-[var(--accent)]" />
                            <span className="flex-1 text-sm text-white truncate">{c.title}</span>
                            <span className="text-xs text-[var(--text-tertiary)] shrink-0">{c.msg_count} 条</span>
                          </label>
                        );
                      })}
                    </div>
                  )
                  : <p className="text-xs text-[var(--text-tertiary)] py-1">暂无已同步的群，请先同步一次，或手动输入群名</p>
              }

              {/* Manual input */}
              <div>
                <p className="text-xs text-[var(--text-tertiary)] mb-1.5">手动添加群名</p>
                <TagInput
                  items={config.conv_list || []}
                  onAdd={t => setConfig(c => ({ ...c, conv_list: [...(c.conv_list || []), t] }))}
                  onRemove={t => setConfig(c => ({ ...c, conv_list: (c.conv_list || []).filter(x => x !== t) }))}
                  placeholder="群名称…"
                  colorClass="blue"
                />
              </div>
            </div>
          )}
        </div>
      )}

      {/* Custom keywords */}
      <div className="space-y-3">
        <p className="text-xs font-medium text-[var(--text-tertiary)] uppercase tracking-wider">自定义关键词</p>
        <div>
          <p className="text-xs text-green-400 mb-1.5">强制包含 <span className="text-[var(--text-tertiary)]">（匹配即 notify，优先级最高）</span></p>
          <TagInput
            items={config.custom_include_kw || []}
            onAdd={kw => setConfig(c => ({ ...c, custom_include_kw: [...(c.custom_include_kw || []), kw] }))}
            onRemove={kw => setConfig(c => ({ ...c, custom_include_kw: (c.custom_include_kw || []).filter(x => x !== kw) }))}
            placeholder="如：作业、期末、紧急…"
            colorClass="blue"
          />
        </div>
        <div>
          <p className="text-xs text-red-400 mb-1.5">强制排除 <span className="text-[var(--text-tertiary)]">（匹配即 drop）</span></p>
          <TagInput
            items={config.custom_exclude_kw || []}
            onAdd={kw => setConfig(c => ({ ...c, custom_exclude_kw: [...(c.custom_exclude_kw || []), kw] }))}
            onRemove={kw => setConfig(c => ({ ...c, custom_exclude_kw: (c.custom_exclude_kw || []).filter(x => x !== kw) }))}
            placeholder="如：广告、打卡…"
            colorClass="red"
          />
        </div>
      </div>

      {/* Save button */}
      <button onClick={save} disabled={saving}
        className="w-full min-h-11 rounded-2xl bg-[var(--accent)] text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-50 flex items-center justify-center gap-2 transition-colors">
        {saving ? <Loader2 size={14} className="animate-spin" /> : saved ? <CheckCircle2 size={14} className="text-green-300" /> : null}
        {saved ? "已保存" : "保存过滤规则"}
      </button>
    </div>
  );
}

// ── Main ───────────────────────────────────────────────────────────────────
export default function DingTalkStatus() {
  const [tab, setTab] = useState("status");
  const [status, setStatus] = useState(null);
  const [loggedIn, setLoggedIn] = useState(null); // null = unknown
  const [loading, setLoading] = useState(true);
  const [syncing, setSyncing] = useState(false);
  const [resuming, setResuming] = useState(false);
  const [conversations, setConversations] = useState([]);
  const [loadingConvs, setLoadingConvs] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [s, l] = await Promise.all([
        apiFetch("/api/dingtalk/status"),
        apiFetch("/api/dingtalk/login-status"),
      ]);
      setStatus(s);
      setLoggedIn(l.logged_in);
    } catch (_) {}
    finally { setLoading(false); }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  useEffect(() => {
    if (tab !== "filter") return;
    setLoadingConvs(true);
    apiFetch("/api/dingtalk/conversations")
      .then(setConversations).catch(() => {})
      .finally(() => setLoadingConvs(false));
  }, [tab]);

  const handleSync = async () => {
    setSyncing(true);
    try { await apiFetch("/api/dingtalk/sync", { method: "POST" }); await refresh(); }
    finally { setSyncing(false); }
  };
  const handleResume = async () => {
    setResuming(true);
    try { await apiFetch("/api/dingtalk/resume", { method: "POST" }); setTimeout(refresh, 2000); }
    finally { setResuming(false); }
  };

  return (
    <div className="max-w-md space-y-4">
      <h2 className="text-lg font-semibold text-white">钉钉</h2>

      {/* Tab bar */}
      <div className="flex gap-1 rounded-xl bg-[var(--deep-bg)] p-1">
        {[["status", "状态", <Clock size={13} />], ["filter", "消息过滤", <Filter size={13} />]].map(([id, label, icon]) => (
          <button key={id} onClick={() => setTab(id)}
            className={`flex flex-1 items-center justify-center gap-1.5 rounded-lg py-2 text-xs font-medium transition-all ${
              tab === id ? "bg-[var(--accent)] text-white" : "text-[var(--text-secondary)] hover:text-white"
            }`}>
            {icon}{label}
          </button>
        ))}
      </div>

      {tab === "status"
        ? <StatusTab status={status} loggedIn={loggedIn} loading={loading}
            syncing={syncing} resuming={resuming}
            onSync={handleSync} onResume={handleResume} onRefresh={refresh}
            onLoginDetected={refresh} />
        : <FilterTab dbConversations={conversations} loadingConvs={loadingConvs} />
      }
    </div>
  );
}
