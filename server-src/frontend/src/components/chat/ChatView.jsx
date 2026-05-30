import { useState, useRef, useEffect, useCallback } from "react";
import { MessageSquare, PanelLeft, Sparkles } from "lucide-react";
import { useSSEStream } from "../../hooks/useSSEStream";
import { fetchMessages } from "../../api/conversations";
import MessageBubble from "./MessageBubble";
import ChatInput from "./ChatInput";
import ModelPicker from "./ModelPicker";

const AUTO_NEW_SESSION_MS = 30 * 60 * 1000; // 30 minutes

export default function ChatView({ conversation, onConversationUpdate, onOpenSidebar, onCreateNewSession }) {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [usage, setUsage] = useState(null);
  const messagesEndRef = useRef(null);
  const lastActivityRef = useRef(Date.now());

  // Load messages when conversation changes
  useEffect(() => {
    if (!conversation) {
      setMessages([]);
      return;
    }
    fetchMessages(conversation.id).then(setMessages).catch(console.error);
  }, [conversation?.id]);

  // Auto-scroll
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Update activity timestamp on new messages
  useEffect(() => {
    if (messages.length > 0) lastActivityRef.current = Date.now();
  }, [messages.length]);

  const { startStream, stopStream, isStreaming } = useSSEStream({
    onText: (chunk) => {
      setMessages((prev) => {
        const last = prev[prev.length - 1];
        if (last?.role === "assistant" && last?._streaming) {
          return [...prev.slice(0, -1), { ...last, content: last.content + chunk }];
        }
        return [...prev, { role: "assistant", content: chunk, _streaming: true }];
      });
    },
    onReasoning: (chunk) => {
      setMessages((prev) => {
        const last = prev[prev.length - 1];
        if (last?.role === "assistant" && last?._streaming) {
          return [
            ...prev.slice(0, -1),
            { ...last, reasoning: (last.reasoning || "") + chunk },
          ];
        }
        return prev;
      });
    },
    onUsage: (u) => setUsage(u),
    onDone: () => {
      setMessages((prev) =>
        prev.map((m) => (m._streaming ? { ...m, _streaming: false } : m))
      );
      if (conversation) {
        fetchMessages(conversation.id).then(setMessages).catch(console.error);
      }
    },
    onError: (msg) => {
      setMessages((prev) => [
        ...prev.filter((m) => !m._streaming),
        { role: "system", content: `Error: ${msg}` },
      ]);
    },
  });

  const handleSend = useCallback(async () => {
    if (!input.trim() || !conversation || isStreaming) return;

    const now = Date.now();
    const idle = now - lastActivityRef.current;
    let activeConv = conversation;

    if (idle > AUTO_NEW_SESSION_MS && onCreateNewSession) {
      const newConv = await onCreateNewSession();
      if (newConv) activeConv = newConv;
    }
    lastActivityRef.current = now;

    const userMsg = { role: "user", content: input.trim() };
    setMessages((prev) => [...prev, userMsg]);
    setInput("");
    startStream(`/api/conversations/${activeConv.id}/chat`, {
      message: input.trim(),
    });
  }, [input, conversation, isStreaming, startStream, onCreateNewSession]);

  if (!conversation) {
    return (
      <div className="flex h-full flex-col bg-[var(--panel-bg)]">
        <MobileHeader title="对话" onOpenSidebar={onOpenSidebar} />
        <div className="flex flex-1 items-center justify-center px-6 text-[var(--text-tertiary)]">
          <div className="max-w-sm text-center">
            <div className="mx-auto mb-5 grid h-20 w-20 place-items-center rounded-[24px] border border-[var(--border)] bg-[var(--surface-2)] text-[var(--accent)] shadow-2xl shadow-black/20">
              <MessageSquare size={34} />
            </div>
            <p className="mb-2 text-2xl font-semibold text-white">ChatBot</p>
            <p className="mb-6 text-sm leading-6">
              选择一个 API 开始对话。手机上可以从左侧抽屉快速切换会话或新建 MiMo 对话。
            </p>
            <button
              onClick={onOpenSidebar}
              className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full bg-[var(--accent)] px-5 text-sm font-semibold text-white shadow-lg shadow-black/25 md:hidden"
            >
              <PanelLeft size={16} />
              打开对话列表
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col bg-[var(--panel-bg)]">
      <header className="glass-header flex min-h-[56px] items-center justify-between gap-3 px-3 md:px-4">
        <div className="flex min-w-0 items-center gap-3">
          <button onClick={onOpenSidebar}
            className="grid h-10 w-10 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] md:hidden"
            aria-label="打开对话列表">
            <PanelLeft size={19} />
          </button>
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold text-white">{conversation.title}</h2>
            <p className="hidden truncate text-xs text-[var(--text-tertiary)] sm:block">
              {conversation.provider_id} · {conversation.model}
            </p>
          </div>
          <ModelPicker conversation={conversation} onUpdate={onConversationUpdate} />
        </div>
        {usage && (
          <span className="hidden rounded-full border border-[var(--border)] bg-[var(--surface)] px-2.5 py-1 text-xs text-[var(--text-tertiary)] sm:inline">
            {usage.input_tokens?.toLocaleString()} in / {usage.output_tokens?.toLocaleString()} out
          </span>
        )}
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto px-3 py-4 md:px-6">
        {messages.length === 0 && (
          <div className="flex h-full items-center justify-center text-center text-[var(--text-tertiary)]">
            <div>
              <Sparkles className="mx-auto mb-3 text-[var(--text-tertiary)]" size={28} />
              <p className="text-sm">发一条消息开始这段对话。</p>
            </div>
          </div>
        )}
        <div className="mx-auto flex w-full max-w-4xl flex-col gap-3 md:gap-4">
        {messages.map((msg, i) => (
          <MessageBubble key={i} message={msg} />
        ))}
        <div ref={messagesEndRef} />
        </div>
      </div>

      <ChatInput
        value={input}
        onChange={setInput}
        onSend={handleSend}
        onStop={stopStream}
        isStreaming={isStreaming}
      />
    </div>
  );
}

function MobileHeader({ title, onOpenSidebar }) {
  return (
    <header className="glass-header flex min-h-[56px] items-center gap-3 px-3 md:hidden">
      <button onClick={onOpenSidebar}
        className="grid h-10 w-10 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
        aria-label="打开对话列表">
        <PanelLeft size={19} />
      </button>
      <p className="text-sm font-semibold text-white">{title}</p>
    </header>
  );
}
