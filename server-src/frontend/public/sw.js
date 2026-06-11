const CACHE_NAME = "chatbot-shell-v5";
const API_CACHE = "chatbot-api-v1";

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(["/", "/manifest.json", "/icon-192.png"]))
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});
self.addEventListener("activate", (e) =>
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => ![CACHE_NAME, API_CACHE].includes(k)).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  )
);

let ACCESS_TOKEN = "";

function headers() {
  return {
    "Content-Type": "application/json",
    ...(ACCESS_TOKEN ? { Authorization: `Bearer ${ACCESS_TOKEN}` } : {}),
  };
}

function postJSON(url, body) {
  return fetch(url, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
    keepalive: true,
  }).catch(() => {});
}

self.addEventListener("message", (event) => {
  if (event.data?.type === "access_token") {
    ACCESS_TOKEN = event.data.token || "";
  }
});

self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  const title = data.title ?? "ChatBot";
  const payload = data.data ?? {};
  const tag = payload.tag ?? data.tag ?? "default";
  const hasActionableItem = Boolean(payload.item_id || tag);
  const options = {
    body: data.body ?? "",
    icon: data.icon ?? "/icon-192.png",
    badge: "/badge-72.png",
    tag,
    data: { ...payload, tag },
    actions: hasActionableItem
      ? [
          { action: "done", title: "完成" },
          { action: "open", title: "查看" },
        ]
      : [],
    vibrate: data.urgency === "high" ? [200, 100, 200] : [100],
    requireInteraction: payload.type === "assignment" || payload.urgency === "high",
  };
  event.waitUntil(
    Promise.all([
      self.registration.showNotification(title, options),
      postJSON("/api/push/received", { tag }),
      self.registration.setAppBadge ? self.registration.setAppBadge(1).catch(() => {}) : Promise.resolve(),
    ])
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname === "/api/dashboard/today") {
    event.respondWith(networkFirst(req, API_CACHE));
    return;
  }
  if (url.pathname.startsWith("/api/")) return;

  // HTML navigations and the entry document must be network-first: serving a
  // cached index.html cache-first replayed a stale build that referenced a
  // deleted bundle hash -> blank page. Fall back to cache only when offline.
  if (req.mode === "navigate" || url.pathname === "/" || url.pathname.endsWith(".html")) {
    event.respondWith(networkFirst(req, CACHE_NAME));
    return;
  }

  // Hashed, immutable build assets are safe to serve cache-first.
  event.respondWith(cacheFirst(req, CACHE_NAME));
});

async function networkFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  try {
    const resp = await fetch(req);
    if (resp.ok) cache.put(req, resp.clone());
    return resp;
  } catch (_) {
    const cached = await cache.match(req);
    if (cached) return cached;
    throw _;
  }
}

async function cacheFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(req);
  if (cached) return cached;
  const resp = await fetch(req);
  if (resp.ok) cache.put(req, resp.clone());
  return resp;
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data ?? {};
  const tag = data.tag ?? event.notification.tag;
  const action = event.action || "open";
  const url = data.type === "assignment" || data.item_id ? "/?tab=overview" : "/";
  const feedback =
    action === "done"
      ? postJSON("/api/notifications/feedback", { action: "done", tag, item_id: data.item_id, source: "sw_action" })
      : Promise.resolve();
  event.waitUntil(
    Promise.all([
      postJSON("/api/push/clicked", { tag }),
      feedback,
    ]).then(() =>
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clients) => {
        const existing = clients.find((c) =>
          c.url.includes(self.location.origin)
        );
        if (existing) {
          existing.focus();
          existing.postMessage({ type: "navigate", url });
        } else {
          self.clients.openWindow(url);
        }
      })
    )
  );
});

self.addEventListener("notificationclose", (event) => {
  const data = event.notification.data ?? {};
  event.waitUntil(
    Promise.all([
      postJSON("/api/push/dismissed", { tag: data.tag ?? event.notification.tag }),
      postJSON("/api/notifications/feedback", {
        action: "dismiss",
        tag: data.tag ?? event.notification.tag,
        item_id: data.item_id,
        source: "sw_close",
      }),
    ])
  );
});
