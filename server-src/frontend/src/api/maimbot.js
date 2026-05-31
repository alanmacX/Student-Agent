import { apiFetch } from "./client";

export function getMaiMBotStatus() {
  return apiFetch("/api/maimbot/status");
}

export function getMaiMBotLogs(container = "core", lines = 100) {
  return apiFetch(`/api/maimbot/logs?container=${container}&lines=${lines}`);
}

export function restartMaiMBot(container = "core") {
  return apiFetch(`/api/maimbot/restart?container=${container}`, { method: "POST" });
}

export function getMaiMBotConfig() {
  return apiFetch("/api/maimbot/config");
}
