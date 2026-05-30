import { useRef, useEffect, useState, useCallback } from "react";
import { Send, Square } from "lucide-react";
import COMMANDS, { filterCommands } from "./commands";

export default function ChatInput({
  value,
  onChange,
  onSend,
  onStop,
  onCommand,
  isStreaming,
  placeholder = "发消息...",
}) {
  const textareaRef = useRef(null);
  const [showPalette, setShowPalette] = useState(false);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [filtered, setFiltered] = useState(COMMANDS);

  useEffect(() => {
    const el = textareaRef.current;
    if (el) {
      el.style.height = "auto";
      el.style.height = Math.min(el.scrollHeight, 200) + "px";
    }
  }, [value]);

  // Show palette when input starts with /
  useEffect(() => {
    if (value.startsWith("/")) {
      const query = value.slice(1).split(" ")[0];
      const cmds = filterCommands(query);
      setFiltered(cmds);
      setSelectedIndex(0);
      setShowPalette(cmds.length > 0);
    } else {
      setShowPalette(false);
    }
  }, [value]);

  const selectCommand = useCallback((cmd) => {
    if (cmd.name === "/clear" || cmd.name === "/status") {
      // Execute immediately
      onCommand?.(cmd.name, "");
      onChange("");
    } else {
      // Fill the command prefix
      onChange(cmd.name + " ");
    }
    setShowPalette(false);
    textareaRef.current?.focus();
  }, [onCommand, onChange]);

  const handleKeyDown = (e) => {
    if (showPalette) {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIndex((i) => (i + 1) % filtered.length);
        return;
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIndex((i) => (i - 1 + filtered.length) % filtered.length);
        return;
      }
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (filtered[selectedIndex]) {
          selectCommand(filtered[selectedIndex]);
        }
        return;
      }
      if (e.key === "Escape") {
        setShowPalette(false);
        return;
      }
    }

    const isMobileWidth = window.matchMedia?.("(max-width: 767px)").matches;
    if (isMobileWidth) return;
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      onSend();
    }
  };

  const handleSend = () => {
    if (value.startsWith("/")) {
      const parts = value.slice(1).split(/\s+/);
      const cmdName = "/" + parts[0];
      const args = parts.slice(1).join(" ");
      onCommand?.(cmdName, args);
      onChange("");
      setShowPalette(false);
      return;
    }
    onSend();
  };

  return (
    <>
      {/* ── Mobile floating pill ────────────────────────────────────── */}
      <div
        className="glass-input md:hidden rounded-[26px]"
        style={{
          position: "fixed",
          bottom: "calc(env(safe-area-inset-bottom) + 84px)",
          left: "14px",
          right: "14px",
          zIndex: 40,
        }}
      >
        {/* Command palette — mobile */}
        {showPalette && (
          <div className="absolute bottom-full left-0 right-0 mb-2 max-h-48 overflow-y-auto rounded-2xl border border-[var(--border)] bg-[var(--panel-bg)] shadow-xl shadow-black/30 backdrop-blur-xl">
            {filtered.map((cmd, i) => (
              <button
                key={cmd.name}
                onClick={() => selectCommand(cmd)}
                className={`flex w-full items-center gap-3 px-4 py-2.5 text-left text-sm transition ${
                  i === selectedIndex ? "bg-[var(--accent)]/20 text-white" : "text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
                }`}
              >
                <cmd.icon size={16} className="text-[var(--accent)]" />
                <div className="flex-1 min-w-0">
                  <span className="font-medium">{cmd.label}</span>
                  <span className="ml-2 text-xs text-[var(--text-tertiary)]">{cmd.hint}</span>
                </div>
                <span className="text-xs text-[var(--text-tertiary)] font-mono">{cmd.name}</span>
              </button>
            ))}
          </div>
        )}
        <div className="flex items-center gap-2 px-3 py-1.5 w-full">
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
              onClick={handleSend}
              disabled={!value.trim()}
              className="grid h-10 w-10 flex-shrink-0 place-items-center rounded-full bg-[var(--accent)] text-white shadow-lg transition hover:bg-[var(--accent-strong)] disabled:bg-white/10 disabled:text-[var(--text-tertiary)] disabled:shadow-none"
              aria-label="发送"
            >
              <Send size={15} />
            </button>
          )}
        </div>
      </div>

      {/* ── Desktop bar ─────────────────────────────────────────────── */}
      <div className="hidden md:block border-t border-[var(--glass-border)] bg-[var(--tab-float-bg)] px-4 pb-3 pt-3 backdrop-blur-xl saturate-150">
        <div className="mx-auto flex max-w-3xl items-end gap-2 relative">
          {/* Command palette — desktop */}
          {showPalette && (
            <div className="absolute bottom-full left-0 mb-2 w-80 max-h-48 overflow-y-auto rounded-2xl border border-[var(--border)] bg-[var(--panel-bg)] shadow-xl shadow-black/30 backdrop-blur-xl z-50">
              {filtered.map((cmd, i) => (
                <button
                  key={cmd.name}
                  onClick={() => selectCommand(cmd)}
                  className={`flex w-full items-center gap-3 px-4 py-2.5 text-left text-sm transition ${
                    i === selectedIndex ? "bg-[var(--accent)]/20 text-white" : "text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
                  }`}
                >
                  <cmd.icon size={16} className="text-[var(--accent)]" />
                  <div className="flex-1 min-w-0">
                    <span className="font-medium">{cmd.label}</span>
                    <span className="ml-2 text-xs text-[var(--text-tertiary)]">{cmd.hint}</span>
                  </div>
                  <span className="text-xs text-[var(--text-tertiary)] font-mono">{cmd.name}</span>
                </button>
              ))}
            </div>
          )}
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
              onClick={handleSend}
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
