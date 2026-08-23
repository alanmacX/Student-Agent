import { useRef, useState, useCallback, useEffect } from "react";
import { getAccessToken, apiFetch } from "../api/client";
import { consumeSSE, dispatchSSEEvent } from "../lib/stream";

/**
 * One streaming request at a time; aborts on unmount.
 * Callbacks live in a ref so `startStream` identity is stable even when
 * callers pass inline closures (the old dep-array version churned identity
 * every render and re-created the callback graph mid-stream).
 */
export function useSSEStream(callbacks) {
  const isStreamingRef = useRef(false);
  const [isStreaming, setIsStreaming] = useState(false);
  const controllerRef = useRef(null);
  const cbRef = useRef(callbacks);
  cbRef.current = callbacks;

  useEffect(() => () => controllerRef.current?.abort(), []);

  const startStream = useCallback(async (url, body) => {
    if (isStreamingRef.current) return;
    isStreamingRef.current = true;
    setIsStreaming(true);
    controllerRef.current = new AbortController();
    try {
      const token = getAccessToken();
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
        signal: controllerRef.current.signal,
      });
      await consumeSSE(resp, (event) => dispatchSSEEvent(event, cbRef.current));
    } catch (err) {
      if (err.name !== "AbortError") cbRef.current.onError?.(err.message);
    } finally {
      isStreamingRef.current = false;
      setIsStreaming(false);
    }
  }, []);

  const stopStream = useCallback(() => {
    controllerRef.current?.abort();
    isStreamingRef.current = false;
    setIsStreaming(false);
  }, []);

  return { startStream, stopStream, isStreaming };
}

// Re-exported for callers that imported it from here historically.
export { apiFetch };
