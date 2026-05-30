import { useState, useEffect } from "react";
import { subscribeToServer, unsubscribeFromServer, getVapidKey } from "../api/push";

export function usePush() {
  const [supported, setSupported] = useState(false);
  const [permission, setPermission] = useState("default");
  const [subscribed, setSubscribed] = useState(false);

  useEffect(() => {
    const isSupported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
    setSupported(isSupported);
    if (!isSupported) return;
    setPermission(Notification.permission);
    navigator.serviceWorker.ready
      .then((reg) => reg.pushManager.getSubscription())
      .then((sub) => setSubscribed(Boolean(sub)))
      .catch(console.error);
  }, []);

  async function subscribe() {
    if (!supported) return { error: "not_supported" };

    const perm = await Notification.requestPermission();
    setPermission(perm);
    if (perm !== "granted") return { error: "denied" };

    const reg = await navigator.serviceWorker.ready;
    const { publicKey } = await getVapidKey();
    if (!publicKey) return { error: "missing_vapid_key" };

    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: _urlBase64ToUint8Array(publicKey),
    });

    await subscribeToServer({
      endpoint: sub.endpoint,
      keys: {
        p256dh: _arrayBufferToBase64(sub.getKey("p256dh")),
        auth: _arrayBufferToBase64(sub.getKey("auth")),
      },
    });
    setSubscribed(true);
    return { ok: true };
  }

  async function unsubscribe() {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) {
      await unsubscribeFromServer({ endpoint: sub.endpoint });
      await sub.unsubscribe();
    }
    setSubscribed(false);
  }

  return { supported, permission, subscribed, subscribe, unsubscribe };
}

function _arrayBufferToBase64(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)));
}

function _urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  return Uint8Array.from([...rawData].map((c) => c.charCodeAt(0)));
}
