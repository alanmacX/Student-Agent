import { useRef, useEffect } from "react";
import { Send, Square } from "lucide-react";

export default function ChatInput({
  value,
  onChange,
  onSend,
  onStop,
  isStreaming,
  placeholder = "发消息...",
}) {
  const textareaRef = useRef(null);

  // Auto-resize textarea
  useEffect(() => {
    const el = textareaRef.current;
    if (el) {
      el.style.height = "auto";
      el.style.height = Math.min(el.scrollHeight, 200) + "px";
    }
  }, [value]);

  const handleKeyDown = (e) => {
    const isMobileWidth = window.matchMedia?.("(max-width: 767px)").matches;
    if (isMobileWidth) return;
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      onSend();
    }
  };

  return (
    <>
      {/* Floating pill — mobile */}
      <div
        className="glass-input md:hidden"
        style={{
          position: "fixed",
          bottom: "calc(env(safe-area-inset-bottom) + 84px)",
          left: "14px",
          right: "14px",
          zIndex: 40,
          display: "flex",
          alignItems: "center",
          gap: "8px",
          padding: "7px 7px 7px 18px",
          borderRadius: "26px",
        }}
      >
        <textarea
          ref={textareaRef}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          rows={1}
          className="max-h-32 min-h-[24px] flex-1 resize-none self-center bg-transparent py-1 text-[15px] leading-6 text-white placeholder-[var(--text-tertiary)] focus:outline-none"
          disabled={isStreaming}
        />
        {isStreaming ? (
          <button
            onClick={onStop}
            className="grid h-10 w-10 flex-shrink-0 place-items-center rounded-full bg-red-600 text-white shadow-lg transition hover:bg-red-700"
            aria-label="停止生成"
          >
            <Square size={15} />
          </button>
        ) : (
          <button
            onClick={onSend}
            disabled={!value.trim()}
            className="grid h-10 w-10 flex-shrink-0 place-items-center rounded-full bg-[var(--accent)] text-white shadow-lg transition hover:bg-[var(--accent-strong)] disabled:bg-white/10 disabled:text-[var(--text-tertiary)] disabled:shadow-none"
            aria-label="发送"
          >
            <Send size={15} />
          </button>
        )}
      </div>

      {/* Desktop — original bar */}
      <div className="hidden md:block border-t border-[var(--glass-border)] bg-[var(--tab-float-bg)] px-4 pb-3 pt-3 backdrop-blur-xl saturate-150">
        <div className="mx-auto flex max-w-3xl items-end gap-2">
          <textarea
            ref={textareaRef}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={placeholder}
            rows={1}
            className="max-h-[200px] min-h-11 flex-1 resize-none rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-4 py-2.5 text-sm leading-6 text-white placeholder-[var(--text-tertiary)] shadow-inner shadow-black/20 focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
            disabled={isStreaming}
          />
          {isStreaming ? (
            <button
              onClick={onStop}
              className="grid h-11 w-11 flex-shrink-0 place-items-center rounded-full bg-red-600 text-white shadow-lg shadow-black/25 transition hover:bg-red-700"
              aria-label="停止生成"
            >
              <Square size={16} />
            </button>
          ) : (
            <button
              onClick={onSend}
              disabled={!value.trim()}
              className="grid h-11 w-11 flex-shrink-0 place-items-center rounded-full bg-[var(--accent)] text-white shadow-lg shadow-black/25 transition hover:bg-[var(--accent-strong)] disabled:cursor-not-allowed disabled:bg-[var(--hover-bg)] disabled:text-[var(--text-tertiary)] disabled:shadow-none"
              aria-label="发送"
            >
              <Send size={16} />
            </button>
          )}
        </div>
      </div>
    </>
  );
}
