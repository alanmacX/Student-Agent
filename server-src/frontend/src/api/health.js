import { apiFetch } from "./client";

export const fetchHealthDetail = () => apiFetch("/api/health/detail");
