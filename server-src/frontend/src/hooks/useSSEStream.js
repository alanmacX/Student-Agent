import { useRef, useState, useCallback, useEffect } from "react";

export function useSSEStream({ onText, onReasoning, onUsage, onToolStart, onToolResult, onSchedulePayload, onPendingConfirmation, onDone, onError }) {
  const isStreamingRef = useRef(false);
  const [isStreaming, setIsStreaming] = useState(false);
  const controllerRef = useRef(null);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      controllerRef.current?.abort();
    };
  }, []);

  const startStream = useCallback(async (url, body) => {
    if (isStreamingRef.current) return;
    isStreamingRef.current = true;
    setIsStreaming(true);
    controllerRef.current = new AbortController();

    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controllerRef.current.signal,
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
              case "text": onText?.(event.content); break;
              case "reasoning": onReasoning?.(event.content); break;
              case "usage": onUsage?.(event.usage); break;
              case "tool_start": onToolStart?.(event.tools); break;
              case "tool_result": onToolResult?.(event); break;
              case "schedule_payload": onSchedulePayload?.(event); break;
              case "pending_confirmation": onPendingConfirmation?.(event); break;
              case "done": onDone?.(); break;
              case "error": onError?.(event.message); break;
              case "cancelled": onDone?.(); break;
            }
          } catch (_) {}
        }
      }
    } catch (err) {
      if (err.name !== "AbortError") {
        onError?.(err.message);
      }
    } finally {
      isStreamingRef.current = false;
      setIsStreaming(false);
    }
  }, [onText, onReasoning, onUsage, onToolStart, onToolResult, onSchedulePayload, onPendingConfirmation, onDone, onError]);

  const stopStream = useCallback(() => {
    controllerRef.current?.abort();
    isStreamingRef.current = false;
    setIsStreaming(false);
  }, []);

  return { startStream, stopStream, isStreaming };
}
