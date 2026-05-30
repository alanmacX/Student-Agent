import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

// iOS Safari ignores user-scalable=no, so block pinch-zoom and double-tap zoom.
["gesturestart", "gesturechange", "gestureend"].forEach((evt) =>
  document.addEventListener(evt, (e) => e.preventDefault(), { passive: false })
);
let lastTouchEnd = 0;
document.addEventListener(
  "touchend",
  (e) => {
    const now = Date.now();
    if (now - lastTouchEnd <= 300) e.preventDefault();
    lastTouchEnd = now;
  },
  { passive: false }
);

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(console.error);
  });
}
