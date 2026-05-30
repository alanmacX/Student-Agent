import { useState, useRef, useEffect, useCallback } from "react";
import { PanelRight, Trash2, X, Upload, Plus, MessageSquare } from "lucide-react";
import { useSSEStream } from "../../hooks/useSSEStream";
import { useScheduleSessions } from "../../hooks/useScheduleSessions";
import MessageBubble from "../chat/MessageBubble";
import ChatInput from "../chat/ChatInput";
import ScheduleSidebar from "./ScheduleSidebar";
import ImportModal from "./ImportModal";

// ── Floating circular action button ───────────────────────────────────────────
function CircleButton({ onClick, title, className = "", children }) {
  return (
    <button
      onClick={onClick}
      title={title}
      className={`glass-pill pointer-events-auto grid h-11 w-11 shrink-0 place-items-center rounded-full text-[var(--text-secondary)] transition-all duration-200 ease-[var(--ease-spring)] hover:scale-105 hover:border-[var(--glass-border-bright)] hover:text-white active:scale-95 ${className}`}
    >
      {children}
    </button>
  );
}

// ── Agent status bar ──────────────────────────────────────────────────────────
function AgentStatusBar({ status }) {
  return (
    <div className="flex items-center gap-2 px-4 py-2 text-xs text-[var(--text-tertiary)]">
      <span className="flex items-center gap-0.5">
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className="inline-block h-1.5 w-1.5 rounded-full bg-[var(--accent)] opacity-70"
            style={{ animation: `pulse 1.2s ease-in-out ${i * 0.2}s infinite` }}
          />
        ))}
      </span>
      <span>{status}</span>
      <style>{`
        @keyframes pulse {
          0%, 80%, 100% { opacity: 0.2; transform: scale(0.8); }
          40% { opacity: 0.9; transform: scale(1.1); }
        }
      `}</style>
    </div>
  );
}

// ── Session item ──────────────────────────────────────────────────────────────
function SessionItem({ session, active, onSelect, onDelete }) {
  const [confirming, setConfirming] = useState(false);

  const handleDelete = (e) => {
    e.stopPropagation();
    if (confirming) {
      onDelete(session.id);
    } else {
      setConfirming(true);
      setTimeout(() => setConfirming(false), 2000);
    }
  };

  return (
    <button
      onClick={() => onSelect(session)}
      className={`group relative flex w-full items-start gap-2 rounded-[14px] px-3 py-2.5 text-left transition-all duration-200 ease-[var(--ease-smooth)] ${
        active
          ? "bg-[var(--accent)]/15 text-white"
          : "text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] hover:text-white"
      }`}
    >
      <MessageSquare size={14} className="mt-0.5 shrink-0 opacity-60" />
      <span className="min-w-0 flex-1 truncate text-xs">{session.title}</span>
      <span
        onClick={handleDelete}
        className={`ml-1 shrink-0 rounded p-0.5 transition-colors ${
          confirming
            ? "text-red-400 opacity-100"
            : "opacity-0 group-hover:opacity-60 hover:!opacity-100 text-[var(--text-tertiary)]"
        }`}
      >
        <Trash2 size={12} />
      </span>
    </button>
  );
}

// ── Sessions panel ────────────────────────────────────────────────────────────
function SessionsPanel({ sessions, activeId, onSelect, onCreate, onDelete }) {
  return (
    <div className="flex h-full w-[200px] flex-col border-r border-[var(--border)] bg-[var(--sidebar-bg)]">
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-3 border-b border-[var(--border)]">
        <span className="text-xs font-semibold text-[var(--text-tertiary)] uppercase tracking-wide">对话</span>
        <button
          onClick={onCreate}
          className="grid h-7 w-7 place-items-center rounded-full text-[var(--text-secondary)] transition-all duration-200 ease-[var(--ease-spring)] hover:bg-[var(--hover-bg)] hover:text-white active:scale-90"
          title="新对话"
        >
          <Plus size={15} />
        </button>
      </div>

      {/* Session list */}
      <div className="flex-1 overflow-y-auto py-1.5 px-1.5 space-y-0.5">
        {sessions.length === 0 && (
          <p className="px-3 py-4 text-center text-xs text-[var(--text-tertiary)]">暂无对话</p>
        )}
        {sessions.map((s) => (
          <SessionItem
            key={s.id}
            session={s}
            active={s.id === activeId}
            onSelect={onSelect}
            onDelete={onDelete}
          />
        ))}
      </div>
    </div>
  );
}

// ── Payload merge helper ─────────────────────────────────────────────────────
function mergePayload(existing, incoming) {
  const keys = ["actions", "courses", "chaoxing_assignments", "chaoxing_messages", "reminders", "events"];
  const merged = { ...existing };
  for (const key of keys) {
    const a = existing[key] || [];
    const b = incoming[key] || [];
    if (b.length > 0) {
      merged[key] = [...a, ...b];
    }
  }
  return merged;
}

// ── Main ──────────────────────────────────────────────────────────────────────
export default function ScheduleView() {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sessionsDrawerOpen, setSessionsDrawerOpen] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [agentStatus, setAgentStatus] = useState("处理中...");
  const [pendingTool, setPendingTool] = useState(null); // { tool }
  const pendingToolRef = useRef(null);
  const [activeSession, setActiveSession] = useState(null); // null = loading
  const messagesEndRef = useRef(null);

  const {
    sessions,
    loading: sessionsLoading,
    createSession,
    deleteSession,
    refreshSessions,
    initSession,
  } = useScheduleSessions();

  // Load messages for the active session
  const loadMessages = useCallback(async (sessionId) => {
    if (!sessionId) return;
    try {
      const res = await fetch(`/api/schedule/sessions/${sessionId}/messages`);
      const data = await res.json();
      // Parse schedule_payload_json for each message
      const parsed = data.map((m) => {
        if (m.schedule_payload_json) {
          try {
            return { ...m, schedulePayload: JSON.parse(m.schedule_payload_json) };
          } catch { return m; }
        }
        return m;
      });
      setMessages(parsed);
    } catch (e) {
      console.error(e);
    }
  }, []);

  // On mount: use initSession to pick or auto-create session (respects 12h rule)
  useEffect(() => {
    if (sessionsLoading) return;
    if (activeSession) return;
    (async () => {
      const id = await initSession();
      if (id) {
        setActiveSession((prev) => prev || sessions.find((s) => s.id === id) || sessions[0] || null);
      }
    })();
  }, [sessionsLoading]);

  // Keep activeSession in sync if sessions list changes (e.g. after delete)
  useEffect(() => {
    if (sessionsLoading || !sessions.length) return;
    if (activeSession && !sessions.find((s) => s.id === activeSession.id)) {
      setActiveSession(sessions[0]);
    }
  }, [sessions, sessionsLoading]);

  // Load messages when session changes
  useEffect(() => {
    if (activeSession?.id) {
      loadMessages(activeSession.id);
    }
  }, [activeSession?.id]);

  // Scroll to bottom
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const { startStream, stopStream, isStreaming } = useSSEStream({
    onText: (chunk) => {
      setAgentStatus("生成回复...");
      setMessages((prev) => {
        const lastIdx = prev.findLastIndex((m) => m.role === "assistant" && m._streaming);
        if (lastIdx !== -1) {
          const updated = [...prev];
          updated[lastIdx] = { ...updated[lastIdx], content: updated[lastIdx].content + chunk };
          return updated;
        }
        return [...prev, { role: "assistant", content: chunk, _streaming: true }];
      });
    },
    onReasoning: (chunk) => {
      setAgentStatus("思考中...");
      setMessages((prev) => {
        const lastIdx = prev.findLastIndex((m) => m.role === "assistant" && m._streaming);
        if (lastIdx !== -1) {
          const updated = [...prev];
          updated[lastIdx] = { ...updated[lastIdx], reasoning: (updated[lastIdx].reasoning || "") + chunk };
          return updated;
        }
        return prev;
      });
    },
    onToolStart: (tools) => {
      setAgentStatus(`调用工具: ${tools.map((t) => t.name).join(", ")}`);
      setMessages((prev) => [
        ...prev,
        ...tools.map((t) => ({
          role: "tool",
          toolName: t.name,
          toolId: t.id,
          result: null,
          startTime: Date.now(),
        })),
      ]);
    },
    onToolResult: (event) => {
      setAgentStatus("处理结果...");
      setMessages((prev) =>
        prev.map((m) =>
          m.role === "tool" && m.toolName === event.tool_name && m.result === null
            ? { ...m, result: event.result_preview, endTime: Date.now() }
            : m
        )
      );
    },
    onSchedulePayload: (event) => {
      setMessages((prev) => {
        const lastIdx = prev.findLastIndex((m) => m.role === "assistant" && m._streaming);
        if (lastIdx !== -1) {
          const updated = [...prev];
          const existing = updated[lastIdx].schedulePayload;
          updated[lastIdx] = {
            ...updated[lastIdx],
            schedulePayload: existing ? mergePayload(existing, event) : event,
          };
          return updated;
        }
        return prev;
      });
    },
    onPendingConfirmation: (event) => {
      const tool = event.tool;
      pendingToolRef.current = tool;
      setPendingTool({ tool });
      setMessages((prev) => {
        const lastIdx = prev.findLastIndex((m) => m.role === "assistant");
        if (lastIdx !== -1) {
          const updated = [...prev];
          updated[lastIdx] = { ...updated[lastIdx], _pendingTool: tool };
          return updated;
        }
        return prev;
      });
    },
    onDone: () => {
      setMessages((prev) =>
        prev.map((m) => (m._streaming ? { ...m, _streaming: false } : m))
      );
      // Refresh session list (title may have updated from first message)
      refreshSessions();
      if (activeSession?.id) {
        loadMessages(activeSession.id);
        // Re-apply pendingTool after DB reload (loadMessages replaces all messages)
        const savedTool = pendingToolRef.current;
        if (savedTool) {
          setTimeout(() => {
            setMessages((prev) => {
              const lastIdx = prev.findLastIndex((m) => m.role === "assistant");
              if (lastIdx !== -1) {
                const updated = [...prev];
                updated[lastIdx] = { ...updated[lastIdx], _pendingTool: savedTool };
                return updated;
              }
              return prev;
            });
          }, 100);
        }
      }
    },
    onError: (msg) => {
      setAgentStatus("出错了");
      setMessages((prev) => [
        ...prev.filter((m) => !m._streaming),
        { role: "system", content: `Error: ${msg}` },
      ]);
    },
  });

  const handleSelectSession = useCallback((session) => {
    setActiveSession(session);
    setSessionsDrawerOpen(false);
  }, []);

  const handleCreateSession = useCallback(async () => {
    const session = await createSession("新对话");
    if (session) {
      setActiveSession(session);
      setMessages([]);
      setSessionsDrawerOpen(false);
    }
  }, [createSession]);

  const handleDeleteSession = useCallback(async (id) => {
    await deleteSession(id);
    if (activeSession?.id === id) {
      // Sessions list will update, useEffect will pick new active
      setActiveSession(null);
      setMessages([]);
    }
  }, [activeSession, deleteSession]);

  const handleConfirm = useCallback(async () => {
    if (isStreaming) return;
    const tool = pendingToolRef.current;
    if (!tool) return;
    pendingToolRef.current = null;
    setPendingTool(null);
    setMessages((prev) => [
      ...prev.map((m) => (m._pendingTool ? { ...m, _pendingTool: undefined } : m)),
      { role: "user", content: "确认" },
    ]);
    setAgentStatus("处理中...");
    startStream("/api/schedule/chat", { message: "确认", session_id: activeSession?.id });
  }, [isStreaming, activeSession, startStream]);

  const handleCancel = useCallback(() => {
    pendingToolRef.current = null;
    setPendingTool(null);
    setMessages((prev) =>
      prev.map((m) => (m._pendingTool ? { ...m, _pendingTool: undefined } : m))
    );
  }, []);

  const handleSend = useCallback(async () => {
    if (!input.trim() || isStreaming) return;
    // Clear pending confirmation if user sends a new message
    if (pendingToolRef.current) {
      pendingToolRef.current = null;
      setPendingTool(null);
    }

    let sessionId = activeSession?.id;

    // Auto-create session if none exists
    if (!sessionId) {
      const session = await createSession("新对话");
      if (!session) return;
      setActiveSession(session);
      sessionId = session.id;
    }

    const userMsg = { role: "user", content: input.trim() };
    setMessages((prev) => [...prev, userMsg]);
    const msgToSend = input.trim();
    setInput("");
    setAgentStatus("处理中...");
    startStream("/api/schedule/chat", { message: msgToSend, session_id: sessionId });
  }, [input, isStreaming, activeSession, startStream, createSession]);

  const handleClearSession = useCallback(async () => {
    if (!activeSession?.id) return;
    await fetch(`/api/schedule/sessions/${activeSession.id}/messages`, { method: "DELETE" });
    setMessages([]);
  }, [activeSession]);

  const sessionTitle = activeSession?.title || "日程 Agent";

  return (
    <div className="flex h-full bg-[var(--panel-bg)]">
      {/* Sessions panel — desktop */}
      <div className="hidden md:block">
        <SessionsPanel
          sessions={sessions}
          activeId={activeSession?.id}
          onSelect={handleSelectSession}
          onCreate={handleCreateSession}
          onDelete={handleDeleteSession}
        />
      </div>

      {/* Main chat area */}
      <div className="relative flex min-w-0 flex-1 flex-col">
        {/* Header — floating island over messages */}
        <div className="pointer-events-none absolute inset-x-0 top-0 z-20 flex items-center gap-2 px-3 pt-3 md:px-4">
          {/* Title island */}
          <div className="glass-pill pointer-events-auto flex min-w-0 flex-1 items-center gap-2 rounded-full px-2 py-2 pr-4">
            {/* Mobile: sessions drawer button */}
            <button
              onClick={() => setSessionsDrawerOpen(true)}
              className="grid h-8 w-8 shrink-0 place-items-center rounded-full text-[var(--text-secondary)] transition-colors hover:bg-[var(--hover-bg)] hover:text-white md:hidden"
              title="对话列表"
            >
              <MessageSquare size={16} />
            </button>
            <h2 className="truncate pl-1 text-sm font-semibold text-white md:pl-3">{sessionTitle}</h2>
          </div>

          {/* Floating circle action buttons */}
          <CircleButton onClick={() => setSidebarOpen(true)} title="打开日程侧栏" className="lg:hidden">
            <PanelRight size={16} />
          </CircleButton>
          <CircleButton onClick={() => setShowImport(true)} title="导入课程表">
            <Upload size={15} />
          </CircleButton>
          <CircleButton onClick={handleClearSession} title="清空当前对话">
            <Trash2 size={15} />
          </CircleButton>
        </div>

        {/* Messages */}
        <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-40 md:px-6 md:pb-3">
          {messages.length === 0 && (
            <div className="flex h-full items-center justify-center text-[var(--text-tertiary)]">
              <div className="text-center px-6">
                <div className="mx-auto mb-5 grid h-16 w-16 place-items-center rounded-3xl bg-[var(--accent)]/12 ring-1 ring-[var(--accent)]/20">
                  <MessageSquare size={28} className="text-[var(--accent-soft)]" />
                </div>
                <p className="mb-2 text-xl font-semibold text-white">今天要安排什么？</p>
                <p className="text-sm leading-relaxed max-w-xs mx-auto">
                  询问课程、作业截止、学习通消息，或让 Agent 帮你整理和创建提醒。
                </p>
                <div className="mt-5 flex flex-wrap justify-center gap-2">
                  {["今天有什么课？", "有哪些作业快到期？", "最近学习通有什么重要消息？"].map((hint) => (
                    <button
                      key={hint}
                      onClick={() => setInput(hint)}
                      className="rounded-full border border-[var(--border)] bg-[var(--surface)] px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] hover:text-white transition-colors"
                    >
                      {hint}
                    </button>
                  ))}
                </div>
                <div className="mt-3 flex flex-wrap justify-center gap-2">
                  {[
                    { cmd: "/status", label: "系统状态" },
                    { cmd: "/scan", label: "扫描学习通" },
                    { cmd: "/memory", label: "查看 Memory" },
                    { cmd: "/push", label: "推送设置" },
                  ].map(({ cmd, label }) => (
                    <button
                      key={cmd}
                      onClick={() => setInput(cmd)}
                      className="rounded-full border border-[var(--accent)]/20 bg-[var(--accent)]/8 px-3 py-1.5 text-xs text-[var(--accent-soft)] hover:bg-[var(--accent)]/15 transition-colors"
                    >
                      {cmd} <span className="opacity-60">{label}</span>
                    </button>
                  ))}
                </div>
              </div>
            </div>
          )}
          <div className="mx-auto flex w-full max-w-4xl flex-col gap-3 md:gap-4">
            {messages.map((msg, i) => (
              <MessageBubble
                key={i}
                message={msg}
                onConfirm={msg._pendingTool ? handleConfirm : undefined}
                onCancel={msg._pendingTool ? handleCancel : undefined}
                pendingToolName={msg._pendingTool}
              />
            ))}
            <div ref={messagesEndRef} />
          </div>
        </div>

        {/* Agent status bar */}
        {isStreaming && <AgentStatusBar status={agentStatus} />}

        {/* Input */}
        <ChatInput
          value={input}
          onChange={setInput}
          onSend={handleSend}
          onStop={stopStream}
          isStreaming={isStreaming}
          placeholder="问问日程、作业或学习通消息..."
        />
      </div>

      {/* Schedule sidebar — desktop */}
      <div className="hidden lg:block">
        <ScheduleSidebar />
      </div>

      {/* Import modal */}
      {showImport && (
        <ImportModal onClose={() => setShowImport(false)} onImported={() => setShowImport(false)} />
      )}

      {/* Mobile: schedule sidebar drawer */}
      {sidebarOpen && (
        <div className="fixed inset-0 z-40 bg-[var(--overlay-bg)] backdrop-blur-sm lg:hidden">
          <div className="absolute inset-y-0 right-0 flex w-[88vw] max-w-[360px] flex-col border-l border-[var(--border)] bg-[var(--sidebar-bg)] shadow-2xl">
            <div className="flex items-center justify-between border-b border-[var(--border)] px-4 py-3">
              <div>
                <p className="text-sm font-semibold">日程侧栏</p>
                <p className="text-xs text-[var(--text-tertiary)]">作业、Memory</p>
              </div>
              <button
                onClick={() => setSidebarOpen(false)}
                className="grid h-9 w-9 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
              >
                <X size={18} />
              </button>
            </div>
            <ScheduleSidebar mobile />
          </div>
        </div>
      )}

      {/* Mobile: sessions drawer */}
      {sessionsDrawerOpen && (
        <div className="fixed inset-0 z-40 bg-[var(--overlay-bg)] backdrop-blur-sm md:hidden">
          <div className="absolute inset-y-0 left-0 flex w-[75vw] max-w-[280px] flex-col border-r border-[var(--border)] bg-[var(--sidebar-bg)] shadow-2xl">
            <div className="flex items-center justify-between border-b border-[var(--border)] px-4 py-3">
              <p className="text-sm font-semibold">对话列表</p>
              <button
                onClick={() => setSessionsDrawerOpen(false)}
                className="grid h-9 w-9 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-2">
              <button
                onClick={handleCreateSession}
                className="flex w-full items-center gap-2 rounded-[14px] px-3 py-2 text-sm text-[var(--text-secondary)] transition-colors hover:bg-[var(--hover-bg)] hover:text-white"
              >
                <Plus size={15} />
                新对话
              </button>
            </div>
            <div className="flex-1 overflow-y-auto px-2 pb-4 space-y-0.5">
              {sessions.map((s) => (
                <SessionItem
                  key={s.id}
                  session={s}
                  active={s.id === activeSession?.id}
                  onSelect={handleSelectSession}
                  onDelete={handleDeleteSession}
                />
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
