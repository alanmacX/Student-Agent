import { useState, useEffect, useMemo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Copy, Check, ChevronDown, ChevronRight, Brain, CheckCircle, XCircle } from "lucide-react";
import ToolCallBubble from "./ToolCallBubble";
import SchedulePayloadView from "../schedule/SchedulePayloadView";

export default function MessageBubble({ message, onConfirm, onCancel, pendingToolName }) {
  const [copied, setCopied] = useState(false);
  const [showReasoning, setShowReasoning] = useState(false);
  const isUser = message.role === "user";
  const isSystem = message.role === "system";
  const isTool = message.role === "tool";
  const reasoning = message.reasoning || message.reasoning_content;

  // Parse schedule payload from DB (JSON string) or from SSE (already object)
  const schedulePayload = useMemo(() => {
    if (message.schedulePayload) return message.schedulePayload;
    if (message.schedule_payload_json) {
      try { return JSON.parse(message.schedule_payload_json); } catch { return null; }
    }
    return null;
  }, [message.schedulePayload, message.schedule_payload_json]);

  // Auto-expand reasoning while streaming, collapse when done
  useEffect(() => {
    if (reasoning) {
      setShowReasoning(!!message._streaming);
    }
  }, [!!message._streaming, !!reasoning]);

  const handleCopy = async () => {
    await navigator.clipboard.writeText(message.content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  // Tool call message
  if (isTool) {
    return (
      <ToolCallBubble
        toolName={message.toolName}
        toolId={message.toolId}
        result={message.result}
        startTime={message.startTime}
        endTime={message.endTime}
      />
    );
  }

  if (isSystem) {
    return (
      <div className="flex justify-center">
        <div className="rounded-full border border-[var(--border)] bg-[var(--surface)] px-3 py-1 text-xs text-[var(--text-tertiary)]">
          {message.content}
        </div>
      </div>
    );
  }

  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`group relative max-w-[92%] rounded-[20px] px-4 py-3 shadow-lg shadow-black/10 md:max-w-[80%] ${
          isUser
            ? "rounded-br-md bg-[var(--accent)] text-white"
            : "rounded-bl-md border border-[var(--border)] bg-[var(--surface-2)] text-[var(--text-primary)]"
        }`}
      >
        {/* Reasoning panel */}
        {reasoning && (
          <div className="mb-2">
            <button
              onClick={() => setShowReasoning(!showReasoning)}
              className="flex items-center gap-1.5 text-xs text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] transition-colors"
            >
              <Brain size={12} className="shrink-0" />
              {showReasoning ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
              <span>思考摘要</span>
              {message._streaming && reasoning && (
                <span className="ml-1 inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-[var(--accent)]" />
              )}
            </button>
            {showReasoning && (
              <div
                className="mt-2 max-h-48 overflow-y-auto rounded-xl p-3 text-xs leading-5 text-[var(--text-secondary)] italic"
                style={{
                  background: "var(--input-bg)",
                  borderLeft: "2px solid var(--accent)",
                }}
              >
                {reasoning}
              </div>
            )}
          </div>
        )}

        {/* Content */}
        <div className={`markdown-body max-w-none break-words text-[15px] leading-7 ${isUser ? "markdown-user" : ""}`}>
          <ReactMarkdown remarkPlugins={[remarkGfm]}>
            {message.content}
          </ReactMarkdown>
        </div>

        {/* Schedule payload (structured cards) */}
        {!isUser && schedulePayload && <SchedulePayloadView payload={schedulePayload} />}

        {/* Confirm/cancel buttons for pending mutations */}
        {!isUser && pendingToolName && onConfirm && (
          <div className="mt-3 flex items-center gap-2">
            <button
              onClick={onConfirm}
              className="flex items-center gap-1.5 rounded-full bg-green-500/15 px-3.5 py-1.5 text-xs font-medium text-green-400 ring-1 ring-green-500/25 transition-all hover:bg-green-500/25 hover:ring-green-500/40 active:scale-95"
            >
              <CheckCircle size={14} />
              确认执行
            </button>
            <button
              onClick={onCancel}
              className="flex items-center gap-1.5 rounded-full bg-[var(--surface)] px-3.5 py-1.5 text-xs font-medium text-[var(--text-secondary)] ring-1 ring-[var(--border)] transition-all hover:bg-[var(--hover-bg)] hover:text-white active:scale-95"
            >
              <XCircle size={14} />
              取消
            </button>
          </div>
        )}

        {/* Copy button */}
        {!isUser && message.content && (
          <button
            onClick={handleCopy}
            className="absolute -right-1.5 -top-1.5 grid h-7 w-7 place-items-center rounded-full border border-[var(--border)] bg-[var(--popover-bg)] text-[var(--text-secondary)] opacity-100 shadow-lg transition hover:text-white md:opacity-0 md:group-hover:opacity-100"
            aria-label="复制"
          >
            {copied ? <Check size={13} className="text-green-400" /> : <Copy size={13} />}
          </button>
        )}

        {/* Streaming indicator */}
        {message._streaming && (
          <span className="ml-0.5 inline-block h-4 w-2 animate-pulse rounded-sm bg-white/45" />
        )}
      </div>
    </div>
  );
}
