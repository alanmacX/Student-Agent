import { useState, useEffect, useMemo, useRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeRaw from "rehype-raw";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import { Copy, Check, ChevronDown, ChevronRight, Brain } from "lucide-react";
import ToolCallBubble from "./ToolCallBubble";
import SchedulePayloadView from "../schedule/SchedulePayloadView";

// Allow the agent to emit compact inline HTML (cards, grids, colored tags) while
// stripping anything dangerous. LLM output can echo untrusted group-message text,
// so we sanitize: no scripts/iframes/event handlers, but keep class + inline style
// and the structural/formatting tags needed for a tidy layout.
const HTML_SCHEMA = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    "*": [...(defaultSchema.attributes?.["*"] || []), "className", "class", "style"],
  },
  tagNames: [
    ...(defaultSchema.tagNames || []),
    "div", "span", "section", "small", "details", "summary",
  ],
};

export default function MessageBubble({ message, onConfirm, onCancel }) {
  const [copied, setCopied] = useState(false);
  // Auto-open while streaming; once the user manually toggles, respect their
  // choice (was: boolean deps made streaming updates miss the effect and the
  // panel snapped shut mid-read after done).
  const [showReasoning, setShowReasoning] = useState(!!message._streaming);
  const userToggledRef = useRef(false);
  const lastAutoRef = useRef(!!message._streaming);
  const [confirmed, setConfirmed] = useState(false);
  const isUser = message.role === "user";
  const isSystem = message.role === "system";
  const isTool = message.role === "tool";
  const reasoning = message.reasoning || message.reasoning_content;

  const schedulePayload = useMemo(() => {
    if (message.schedulePayload) return message.schedulePayload;
    if (message.schedule_payload_json) {
      try { return JSON.parse(message.schedule_payload_json); } catch { return null; }
    }
    return null;
  }, [message.schedulePayload, message.schedule_payload_json]);

  const pending = message.pendingConfirmation;

  useEffect(() => {
    const streaming = !!message._streaming;
    if (streaming !== lastAutoRef.current) {
      lastAutoRef.current = streaming;
      if (!userToggledRef.current) setShowReasoning(streaming && !!reasoning);
    } else if (streaming && !reasoning) {
      setShowReasoning(false);
    }
  }, [message._streaming, reasoning]);

  const handleCopy = async () => {
    await navigator.clipboard.writeText(message.content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

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
        {reasoning && (
          <div className="mb-2">
            <button onClick={() => { userToggledRef.current = true; setShowReasoning(!showReasoning); }}
              className="flex items-center gap-1.5 text-xs text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] transition-colors">
              <Brain size={12} className="shrink-0" />
              {showReasoning ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
              <span>思考摘要</span>
              {message._streaming && reasoning && (
                <span className="ml-1 inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-[var(--accent)]" />
              )}
            </button>
            {showReasoning && (
              <div className="mt-2 max-h-48 overflow-y-auto rounded-xl p-3 text-xs leading-5 text-[var(--text-secondary)] italic"
                style={{ background: "var(--input-bg)", borderLeft: "2px solid var(--accent)" }}>
                {reasoning}
              </div>
            )}
          </div>
        )}

        <div className={`markdown-body max-w-none break-words text-[15px] leading-7 ${isUser ? "markdown-user" : ""}`}>
          <ReactMarkdown
            remarkPlugins={[remarkGfm]}
            rehypePlugins={[rehypeRaw, [rehypeSanitize, HTML_SCHEMA]]}
          >{message.content}</ReactMarkdown>
        </div>

        {!isUser && schedulePayload && <SchedulePayloadView payload={schedulePayload} />}

        {/* Confirm / Cancel buttons for pending mutations */}
        {pending && !confirmed && (
          <div className="mt-3 flex gap-2">
            <button
              onClick={() => { setConfirmed(true); onConfirm?.(); }}
              className="flex-1 min-h-10 rounded-2xl bg-[var(--accent)] text-sm font-semibold text-white hover:bg-[var(--accent-strong)]"
            >
              ✓ 确认执行
            </button>
            <button
              onClick={() => { setConfirmed(true); onCancel?.(); }}
              className="min-h-10 rounded-2xl bg-[var(--hover-bg)] px-4 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg-strong)]"
            >
              取消
            </button>
          </div>
        )}

        {!isUser && message.content && (
          <button onClick={handleCopy}
            className="absolute -right-1.5 -top-1.5 grid h-7 w-7 place-items-center rounded-full border border-[var(--border)] bg-[var(--popover-bg)] text-[var(--text-secondary)] opacity-100 shadow-lg transition hover:text-white md:opacity-0 md:group-hover:opacity-100"
            aria-label="复制">
            {copied ? <Check size={13} className="text-green-400" /> : <Copy size={13} />}
          </button>
        )}

        {message._streaming && (
          <span className="ml-0.5 inline-block h-4 w-2 animate-pulse rounded-sm bg-white/45" />
        )}
      </div>
    </div>
  );
}
