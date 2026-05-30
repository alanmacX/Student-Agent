const BASE_URL = "";

export async function apiFetch(path, options = {}) {
  const resp = await fetch(`${BASE_URL}${path}`, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });
  if (!resp.ok) {
    throw new Error(`HTTP ${resp.status}: ${await resp.text()}`);
  }
  return resp.json();
}

export function apiStream(path, body, callbacks) {
  const controller = new AbortController();

  (async () => {
    try {
      const resp = await fetch(`${BASE_URL}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop();

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const payload = line.slice(6).trim();
          if (!payload) continue;

          try {
            const event = JSON.parse(payload);
            switch (event.type) {
              case "text":
                callbacks.onText?.(event.content);
                break;
              case "reasoning":
                callbacks.onReasoning?.(event.content);
                break;
              case "usage":
                callbacks.onUsage?.(event.usage);
                break;
              case "tool_start":
                callbacks.onToolStart?.(event.tools);
                break;
              case "tool_result":
                callbacks.onToolResult?.(event);
                break;
              case "pending_confirmation":
                callbacks.onPendingConfirmation?.(event);
                break;
              case "done":
                callbacks.onDone?.();
                break;
              case "error":
                callbacks.onError?.(event.message);
                break;
              case "cancelled":
                callbacks.onDone?.();
                break;
            }
          } catch (_) {}
        }
      }
    } catch (err) {
      if (err.name !== "AbortError") {
        callbacks.onError?.(err.message);
      }
    }
  })();

  return controller;
}
