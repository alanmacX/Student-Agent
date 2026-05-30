self.addEventListener("install", (e) => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  const title = data.title ?? "ChatBot";
  const options = {
    body: data.body ?? "",
    icon: data.icon ?? "/icon-192.png",
    badge: "/badge-72.png",
    tag: data.tag ?? "default",
    data: data.data ?? {},
    vibrate: data.urgency === "high" ? [200, 100, 200] : [100],
    requireInteraction: data.data?.type === "assignment",
  };
  event.waitUntil(
    Promise.all([
      self.registration.showNotification(title, options),
      fetch("/api/push/received", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tag: options.data?.tag ?? options.tag }),
        keepalive: true,
      }).catch(() => {}),
    ])
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data ?? {};
  const url = data.type === "assignment" ? "/?tab=overview" : "/";
  event.waitUntil(
    fetch("/api/push/clicked", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tag: data.tag ?? event.notification.tag }),
      keepalive: true,
    }).catch(() => {}).then(() =>
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
    fetch("/api/push/dismissed", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tag: data.tag ?? event.notification.tag }),
      keepalive: true,
    }).catch(() => {})
  );
});
