import { useState } from "react";
import { Globe, Bell, Calendar, Wrench, Check, ChevronDown, ChevronRight, Brain, Search, Settings, RefreshCw, Zap } from "lucide-react";

const TOOL_META = {
  fetch_url: { icon: Globe, label: "读取网页" },
  search_web: { icon: Search, label: "搜索" },
  send_push_notification: { icon: Bell, label: "发送推送" },
  get_schedule_context: { icon: Calendar, label: "读取日程" },
  read_message_memory: { icon: Brain, label: "读取 Memory" },
  get_chaoxing_assignments: { icon: Calendar, label: "读取学习通作业" },
  get_chaoxing_messages: { icon: Calendar, label: "读取学习通消息" },
  get_memory_insights: { icon: Brain, label: "读取 Memory" },
  get_system_status: { icon: Zap, label: "检查系统状态" },
  trigger_memory_scan: { icon: RefreshCw, label: "扫描学习通" },
  refresh_message_memory: { icon: RefreshCw, label: "刷新 Memory" },
  set_push_config: { icon: Settings, label: "更新推送设置" },
  list_reminders: { icon: Calendar, label: "读取提醒" },
  list_courses: { icon: Calendar, label: "读取课程表" },
  list_calendar_events: { icon: Calendar, label: "读取日历事件" },
  list_scheduled_notifications: { icon: Bell, label: "读取待发通知" },
  create_reminder: { icon: Calendar, label: "创建提醒" },
  update_reminder: { icon: Calendar, label: "修改提醒" },
  complete_reminder: { icon: Check, label: "完成提醒" },
  delete_reminder: { icon: Calendar, label: "删除提醒" },
  create_calendar_event: { icon: Calendar, label: "创建日历事件" },
  update_calendar_event: { icon: Calendar, label: "修改日历事件" },
  delete_calendar_event: { icon: Calendar, label: "删除日历事件" },
  schedule_notification: { icon: Bell, label: "安排通知" },
  cancel_scheduled_notification: { icon: Bell, label: "取消通知" },
  delete_message_memory: { icon: Brain, label: "删除 Memory" },
};

function ToolIcon({ toolName, size = 14 }) {
  const meta = TOOL_META[toolName];
  if (meta) {
    const Icon = meta.icon;
    return <Icon size={size} />;
  }
  if (/fetch_url|search_web|browse/i.test(toolName)) return <Globe size={size} />;
  if (/push_notification|notify|send_push/i.test(toolName)) return <Bell size={size} />;
  if (/schedule|calendar|reminder|event|deadline/i.test(toolName)) return <Calendar size={size} />;
  if (/memory|insight|scan/i.test(toolName)) return <Brain size={size} />;
  return <Wrench size={size} />;
}

function toolLabel(toolName) {
  const meta = TOOL_META[toolName];
  return meta?.label || toolName;
}

function summarizeResult(result) {
  if (!result) return null;
  try {
    const parsed = JSON.parse(result);
    if (parsed.ok !== undefined) return parsed.ok ? "成功" : "失败";
    if (parsed.error) return `错误: ${parsed.error}`;
    if (Array.isArray(parsed)) return `${parsed.length} 条结果`;
    if (parsed.attempted !== undefined) return `已发送 ${parsed.attempted} 条`;
  } catch {}
  // Truncate long text
  const text = result.trim();
  if (text.length > 120) return text.slice(0, 120) + "...";
  return text;
}

function Spinner() {
  return (
    <span className="inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-[var(--border)] border-t-[var(--accent)]" />
  );
}

function formatDuration(startTime, endTime) {
  const ms = endTime - startTime;
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

export default function ToolCallBubble({ toolName, toolId, result, startTime, endTime }) {
  const [expanded, setExpanded] = useState(false);
  const isRunning = result === null || result === undefined;
  const lines = result ? result.split("\n") : [];
  const isTruncated = lines.length > 3;
  const previewText = isTruncated ? lines.slice(0, 3).join("\n") + "…" : result;

  return (
    <div className="flex justify-start">
      <div className="max-w-[92%] md:max-w-[80%]">
        <div
          className={`rounded-2xl border px-3 py-2 text-xs transition-all ${
            isRunning
              ? "border-[var(--border)] bg-[var(--surface)]"
              : "border-[var(--border)] bg-[var(--surface)]"
          }`}
        >
          {/* Header row */}
          <div className="flex items-center gap-2">
            {isRunning ? (
              <Spinner />
            ) : (
              <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full bg-green-500/20 text-green-400">
                <Check size={10} strokeWidth={3} />
              </span>
            )}

            <span className="flex items-center gap-1.5 text-[var(--text-secondary)]">
              <ToolIcon toolName={toolName} size={12} />
              <span className="font-medium text-[var(--text-primary)]">{toolLabel(toolName)}</span>
            </span>

            {isRunning ? (
              <span className="text-[var(--text-tertiary)]">{toolLabel(toolName)}中...</span>
            ) : (
              <span className="ml-auto rounded-full border border-[var(--border)] bg-[var(--surface-2)] px-2 py-0.5 text-[10px] text-[var(--text-tertiary)]">
                {formatDuration(startTime, endTime)}
              </span>
            )}

            {!isRunning && result && (
              <button
                onClick={() => setExpanded(!expanded)}
                className="ml-1 flex items-center gap-0.5 text-[var(--text-tertiary)] hover:text-[var(--text-secondary)]"
                aria-label={expanded ? "收起" : "展开"}
              >
                {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
              </button>
            )}
          </div>

          {/* Result preview */}
          {!isRunning && result && (
            <>
              {/* Friendly summary (always visible) */}
              <p className="mt-1.5 text-xs text-[var(--text-tertiary)]">{summarizeResult(result)}</p>
              {/* Full result (collapsible) */}
              {(isTruncated || expanded) && (
                <div className="mt-1.5 overflow-hidden rounded-lg border border-[var(--border)] bg-black/20">
                  <pre className="overflow-x-auto whitespace-pre-wrap break-all p-2 font-mono text-[11px] leading-5 text-[var(--text-secondary)]">
                    {expanded ? result : previewText}
                  </pre>
                  {isTruncated && !expanded && (
                    <button
                      onClick={() => setExpanded(true)}
                      className="w-full border-t border-[var(--border)] py-1 text-center text-[10px] text-[var(--accent)] hover:bg-white/5"
                    >
                      展开完整结果
                    </button>
                  )}
                  {expanded && (
                    <button
                      onClick={() => setExpanded(false)}
                      className="w-full border-t border-[var(--border)] py-1 text-center text-[10px] text-[var(--text-tertiary)] hover:bg-white/5"
                    >
                      收起
                    </button>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
