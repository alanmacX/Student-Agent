import { apiFetch } from "./client";

export const fetchProviders = () => apiFetch("/api/providers");

export const addCustomProvider = (data) =>
  apiFetch("/api/providers/custom", { method: "POST", body: JSON.stringify(data) });

export const deleteCustomProvider = (id) =>
  apiFetch(`/api/providers/custom/${id}`, { method: "DELETE" });

export const fetchBalance = (providerId) =>
  apiFetch(`/api/providers/${providerId}/balance`);

export const checkReachability = (providerId) =>
  apiFetch(`/api/providers/${providerId}/reachability`);

export const fetchModels = (providerId) =>
  apiFetch(`/api/providers/${providerId}/models`);
