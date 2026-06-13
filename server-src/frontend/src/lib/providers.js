export const FALLBACK_PROVIDERS = [
  {
    id: "openai",
    name: "OpenAI",
    models: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini"],
    color_hex: "10A37F",
  },
  {
    id: "anthropic",
    name: "Anthropic",
    models: ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
    color_hex: "CC785C",
  },
  {
    id: "gemini",
    name: "Gemini",
    models: ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"],
    color_hex: "4285F4",
  },
  {
    id: "xiaomimimo",
    name: "小米 MiMo",
    models: ["mimo-v2.5-pro"],
    color_hex: "FF6900",
  },
  {
    id: "deepseek",
    name: "DeepSeek",
    models: ["deepseek-v4-flash", "deepseek-v4-pro"],
    color_hex: "4D6BFF",
  },
];

export function mergeProviders(data) {
  if (!data) return FALLBACK_PROVIDERS;
  const builtins = (data.builtin || []).map((provider) => {
    const fallback = FALLBACK_PROVIDERS.find((p) => p.id === provider.id) || {};
    return {
      ...fallback,
      ...provider,
      models: provider.models?.length ? provider.models : fallback.models || [],
    };
  });
  return [...builtins, ...(data.custom || [])];
}

export function providerMeta(providerId, providers = FALLBACK_PROVIDERS) {
  const normalized = normalizeProviderId(providerId);
  return providers.find((provider) => provider.id === normalized) ||
    FALLBACK_PROVIDERS.find((provider) => provider.id === normalized) ||
    { id: providerId, name: providerId || "Provider", models: [], color_hex: "6B7280" };
}

export function normalizeProviderId(providerId) {
  if (providerId === "mimo") return "xiaomimimo";
  if (providerId === "deepseek-v4") return "deepseek";
  return providerId;
}

export function defaultModel(provider) {
  return provider?.models?.[0] || "gpt-4o-mini";
}

export function providerColor(provider) {
  const hex = provider?.color_hex || provider?.colorHex || "6B7280";
  return hex.startsWith("#") ? hex : `#${hex}`;
}
