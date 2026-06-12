import { useState, useRef, useEffect, useCallback } from "react";
import { Trash2, X, Upload, Plus, MessageSquare } from "lucide-react";
import { useSSEStream } from "../../hooks/useSSEStream";
import { useScheduleSessions } from "../../hooks/useScheduleSessions";
import { apiFetch } from "../../api/client";
import { createReminder } from "../../api/reminders";
import MessageBubble from "../chat/MessageBubble";
import ChatInput from "../chat/ChatInput";
import ImportModal from "./ImportModal";

const AUTO_NEW_SESSION_MS = 30 * 60 * 1000; // 30 minutes

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
  const [sessionsDrawerOpen, setSessionsDrawerOpen] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [agentStatus, setAgentStatus] = useState("处理中...");
  const [activeSession, setActiveSession] = useState(null); // null = loading
  const messagesEndRef = useRef(null);
  const lastActivityRef = useRef(Date.now());
  const pendingConfirmRef = useRef(null); // persists pendingConfirmation across DB reloads

  const {
    sessions,
    loading: sessionsLoading,
    createSession,
    deleteSession,
    refreshSessions,
    initSession,
  } = useScheduleSessions();

  // Load messages for the active session. Returns parsed array so callers can
  // re-apply transient state (e.g. pendingConfirmation) after the DB reload.
  const loadMessages = useCallback(async (sessionId) => {
    if (!sessionId) return null;
    try {
      const data = await apiFetch(`/api/schedule/sessions/${sessionId}/messages`);
      const parsed = data.map((m) => {
        if (m.schedule_payload_json) {
          try {
            return { ...m, schedulePayload: JSON.parse(m.schedule_payload_json) };
          } catch { return m; }
        }
        return m;
      });
      setMessages(parsed);
      return parsed;
    } catch (e) {
      console.error(e);
      return null;
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

  useEffect(() => {
    const handler = (event) => {
      if (event.detail?.tab && event.detail.tab !== "agent") return;
      refreshSessions();
      if (activeSession?.id) loadMessages(activeSession.id);
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, [activeSession?.id, loadMessages, refreshSessions]);

  // Scroll to bottom
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Update activity timestamp on new messages
  useEffect(() => {
    if (messages.length > 0) lastActivityRef.current = Date.now();
  }, [messages.length]);

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
      const pending = {
        tool: event.tool,
        arguments: event.arguments,
        description: event.description,
      };
      pendingConfirmRef.current = pending;
      setAgentStatus("等待确认");
      setMessages((prev) => {
        const stopped = prev.map((m) => (m._streaming ? { ...m, _streaming: false } : m));
        const lastIdx = stopped.findLastIndex((m) => m.role === "assistant");
        if (lastIdx !== -1) {
          const updated = [...stopped];
          updated[lastIdx] = { ...updated[lastIdx], pendingConfirmation: pending };
          return updated;
        }
        return [...stopped, { role: "assistant", content: "", _streaming: false, pendingConfirmation: pending }];
      });
    },
    onDone: async () => {
      setMessages((prev) =>
        prev.map((m) => (m._streaming ? { ...m, _streaming: false } : m))
      );
      refreshSessions();
      // If a confirmation is pending, the in-memory message already carries the
      // button — reloading from the DB (which has no transient pendingConfirmation)
      // wipes it and the re-attach was racy. Skip the reload until the user
      // confirms/cancels (handleConfirm/handleCancel reload afterwards).
      if (pendingConfirmRef.current) return;
      if (activeSession?.id) {
        await loadMessages(activeSession.id);
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
    return session;
  }, [createSession]);

  const handleDeleteSession = useCallback(async (id) => {
    await deleteSession(id);
    if (activeSession?.id === id) {
      // Sessions list will update, useEffect will pick new active
      setActiveSession(null);
      setMessages([]);
    }
  }, [activeSession, deleteSession]);

  const handleSend = useCallback(async () => {
    if (!input.trim() || isStreaming) return;

    const now = Date.now();
    const idle = now - lastActivityRef.current;
    let sessionId = activeSession?.id;

    // Auto-create new session if idle > 30 min
    if (sessionId && idle > AUTO_NEW_SESSION_MS) {
      const session = await createSession("新对话");
      if (session) {
        setActiveSession(session);
        setMessages([]);
        sessionId = session.id;
      }
    }

    // Auto-create session if none exists
    if (!sessionId) {
      const session = await createSession("新对话");
      if (!session) return;
      setActiveSession(session);
      sessionId = session.id;
    }

    lastActivityRef.current = now;

    const userMsg = { role: "user", content: input.trim() };
    setMessages((prev) => [...prev, userMsg]);
    const msgToSend = input.trim();
    setInput("");
    setAgentStatus("处理中...");
    startStream("/api/schedule/chat", { message: msgToSend, session_id: sessionId });
  }, [input, isStreaming, activeSession, startStream, createSession]);

  const handleCommand = useCallback(async (cmdName, args) => {
    if (cmdName === "/remind") {
      if (!args.trim()) {
        setMessages((prev) => [...prev, { role: "system", content: "用法: /remind 提醒内容" }]);
        return;
      }
      try {
        await createReminder({ title: args.trim() });
        setMessages((prev) => [...prev, { role: "system", content: `已创建提醒: ${args.trim()}` }]);
      } catch (e) {
        setMessages((prev) => [...prev, { role: "system", content: `创建失败: ${e.message}` }]);
      }
    } else if (cmdName === "/note") {
      if (!args.trim()) {
        setMessages((prev) => [...prev, { role: "system", content: "用法: /note 笔记内容" }]);
        return;
      }
      try {
        const notes = JSON.parse(localStorage.getItem("hub_quick_notes") || "[]");
        notes.unshift({ id: Date.now(), text: args.trim(), created: new Date().toISOString() });
        localStorage.setItem("hub_quick_notes", JSON.stringify(notes));
        setMessages((prev) => [...prev, { role: "system", content: `已保存笔记: ${args.trim()}` }]);
      } catch {
        setMessages((prev) => [...prev, { role: "system", content: "保存失败" }]);
      }
    } else if (cmdName === "/status") {
      // Send as normal agent message
      setInput("检查服务器状态");
      setTimeout(() => handleSend(), 50);
    } else if (cmdName === "/clear") {
      setMessages([]);
      createSession("新对话").then((s) => { if (s) setActiveSession(s); });
    } else {
      // Unknown command — send as normal message
      setInput(cmdName + (args ? " " + args : ""));
    }
  }, [handleSend, createSession, setActiveSession]);

  const handleConfirm = useCallback(async () => {
    if (isStreaming) return;
    pendingConfirmRef.current = null;
    lastActivityRef.current = Date.now();
    setMessages((prev) => [
      ...prev.map((m) => (m.pendingConfirmation ? { ...m, pendingConfirmation: undefined } : m)),
      { role: "user", content: "确认执行" },
    ]);
    setAgentStatus("执行中...");
    try {
      const res = await apiFetch("/api/schedule/confirm", {
        method: "POST",
        body: JSON.stringify({ action: "confirm", session_id: activeSession?.id }),
      });
      if (res.ok) {
        setMessages((prev) => [
          ...prev,
          { role: "assistant", content: typeof res.result === "string" ? res.result : JSON.stringify(res.result, null, 2) },
        ]);
        if (activeSession?.id) loadMessages(activeSession.id);
      } else {
        setMessages((prev) => [...prev, { role: "system", content: `执行失败: ${res.error}` }]);
      }
    } catch (e) {
      setMessages((prev) => [...prev, { role: "system", content: `请求失败: ${e.message}` }]);
    }
    setAgentStatus("");
  }, [isStreaming, activeSession, loadMessages]);

  const handleCancel = useCallback(async () => {
    if (isStreaming) return;
    pendingConfirmRef.current = null;
    lastActivityRef.current = Date.now();
    setMessages((prev) => [
      ...prev.map((m) => (m.pendingConfirmation ? { ...m, pendingConfirmation: undefined } : m)),
      { role: "user", content: "取消" },
      { role: "assistant", content: "已取消操作。" },
    ]);
    try {
      await apiFetch("/api/schedule/confirm", {
        method: "POST",
        body: JSON.stringify({ action: "cancel", session_id: activeSession?.id }),
      });
    } catch (_) {}
    setAgentStatus("");
  }, [isStreaming, activeSession]);

  const handleClearSession = useCallback(async () => {
    if (!activeSession?.id) return;
    await apiFetch(`/api/schedule/sessions/${activeSession.id}/messages`, { method: "DELETE" });
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
              <MessageBubble key={i} message={msg} onConfirm={handleConfirm} onCancel={handleCancel} />
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
          onCommand={handleCommand}
          isStreaming={isStreaming}
          placeholder="问问日程、作业或学习通消息..."
        />
      </div>

      {/* Import modal */}
      {showImport && (
        <ImportModal onClose={() => setShowImport(false)} onImported={() => setShowImport(false)} />
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
