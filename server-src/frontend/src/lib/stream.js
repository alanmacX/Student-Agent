// ── Shared SSE stream parser ───────────────────────────────────────────────
// Single implementation of the backend's `data: {json}\n\n` protocol, used by
// both apiStream() and useSSEStream (previously two diverging copies).

/**
 * Read an SSE Response body and dispatch typed events.
 * Returns when the stream ends. Throws on HTTP errors; AbortError is rethrown
 * so callers can distinguish user-cancel.
 */
export async function consumeSSE(resp, onEvent) {
  if (!resp.ok) {
    if (resp.status === 401 && typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("access-token-required"));
    }
    throw new Error(`HTTP ${resp.status}`);
  }
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop(); // last chunk may be partial — keep for next round
    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice(6).trim();
      if (!payload) continue;
      let event;
      try {
        event = JSON.parse(payload);
      } catch (_) {
        continue; // malformed frame — skip rather than kill the stream
      }
      onEvent(event);
    }
  }
}

/** Map a parsed SSE event to named callbacks. Shared by every consumer. */
export function dispatchSSEEvent(event, cb = {}) {
  switch (event.type) {
    case "text": cb.onText?.(event.content); break;
    case "reasoning": cb.onReasoning?.(event.content); break;
    case "usage": cb.onUsage?.(event.usage); break;
    case "tool_start": cb.onToolStart?.(event.tools); break;
    case "tool_result": cb.onToolResult?.(event); break;
    case "schedule_payload": cb.onSchedulePayload?.(event); break;
    case "pending_confirmation": cb.onPendingConfirmation?.(event); break;
    case "done": cb.onDone?.(); break;
    case "error": cb.onError?.(event.message); break;
    case "cancelled": cb.onDone?.(); break;
    default: break;
  }
}
