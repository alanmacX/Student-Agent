import { consumeSSE, dispatchSSEEvent } from "../lib/stream";

const BASE_URL = "";
const TOKEN_KEY = "access_token";

export function getAccessToken() {
  return localStorage.getItem(TOKEN_KEY) || "";
}

export function setAccessToken(token) {
  const clean = (token || "").trim();
  if (clean) localStorage.setItem(TOKEN_KEY, clean);
  else localStorage.removeItem(TOKEN_KEY);
  broadcastAccessToken();
}

export function clearAccessToken() {
  localStorage.removeItem(TOKEN_KEY);
  broadcastAccessToken();
}

export function broadcastAccessToken() {
  const token = getAccessToken();
  navigator.serviceWorker?.controller?.postMessage?.({ type: "access_token", token });
}

function authHeaders(headers = {}) {
  const token = getAccessToken();
  return {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...headers,
  };
}

async function parseError(resp) {
  let detail = "";
  try {
    detail = await resp.text();
  } catch (_) { /* body already consumed */ }
  throw new Error(`HTTP ${resp.status}: ${detail}`);
}

async function request(path, options = {}, transform) {
  const { headers, ...rest } = options;
  const resp = await fetch(`${BASE_URL}${path}`, {
    ...rest,
    headers: authHeaders(headers),
  });
  if (!resp.ok) {
    if (resp.status === 401) {
      window.dispatchEvent(new CustomEvent("access-token-required"));
    }
    await parseError(resp);
  }
  return transform(resp);
}

export function apiFetch(path, options = {}) {
  return request(path, options, (r) => r.json());
}

export function apiFetchBlob(path, options = {}) {
  return request(path, options, (r) => r.blob());
}

/** POST + stream SSE events to callbacks. Returns an AbortController. */
export function apiStream(path, body, callbacks) {
  const controller = new AbortController();

  (async () => {
    try {
      const resp = await fetch(`${BASE_URL}${path}`, {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      await consumeSSE(resp, (event) => dispatchSSEEvent(event, callbacks));
    } catch (err) {
      if (err.name !== "AbortError") callbacks.onError?.(err.message);
    }
  })();

  return controller;
}
