import { useState, useEffect } from "react";
import { ChevronDown } from "lucide-react";
import { fetchProviders } from "../../api/providers";
import { updateConversation } from "../../api/conversations";
import { FALLBACK_PROVIDERS, mergeProviders, normalizeProviderId, providerColor, providerMeta } from "../../lib/providers";

export default function ModelPicker({ conversation, onUpdate }) {
  const [open, setOpen] = useState(false);
  const [providers, setProviders] = useState(FALLBACK_PROVIDERS);

  useEffect(() => {
    fetchProviders()
      .then((data) => setProviders(mergeProviders(data)))
      .catch(() => {});
  }, []);

  const handleChange = async (providerId, model) => {
    await updateConversation(conversation.id, { provider_id: providerId, model });
    onUpdate?.({ ...conversation, provider_id: providerId, model });
    setOpen(false);
  };

  const currentProvider = providerMeta(conversation.provider_id, providers);

  return (
    <div className="relative min-w-0">
      <button
        onClick={() => setOpen(!open)}
        className="flex max-w-[46vw] items-center gap-1.5 rounded-full border border-[var(--border)] bg-[var(--surface-2)] px-2.5 py-1.5 text-xs text-[var(--text-secondary)] transition hover:bg-[var(--hover-bg)] hover:text-white sm:max-w-xs"
      >
        <span
          className="h-1.5 w-1.5 rounded-full"
          style={{ backgroundColor: providerColor(currentProvider) }}
        />
        <span className="truncate">{conversation.model}</span>
        <ChevronDown size={12} />
      </button>

      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setOpen(false)} />
          <div className="fixed left-3 right-3 top-[62px] z-20 max-h-[70dvh] overflow-y-auto rounded-2xl border border-[var(--border)] bg-[var(--popover-bg)] p-2 shadow-2xl shadow-black/35 backdrop-blur-xl sm:absolute sm:left-0 sm:right-auto sm:top-full sm:mt-2 sm:min-w-[260px]">
            {providers.map((p) => (
              <div key={p.id} className="py-1">
                <div className="flex items-center gap-2 px-3 py-1.5 text-xs font-semibold text-[var(--text-tertiary)]">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: providerColor(p) }}
                  />
                  {p.name}
                </div>
                {p.models?.map((m) => (
                  <button
                    key={m}
                    onClick={() => handleChange(p.id, m)}
                    className={`flex min-h-10 w-full items-center rounded-xl px-3 text-left text-sm transition hover:bg-[var(--hover-bg)] ${
                      normalizeProviderId(conversation.provider_id) === p.id && conversation.model === m
                        ? "bg-[var(--hover-bg)] text-white"
                        : "text-[var(--text-secondary)]"
                    }`}
                  >
                    {m}
                  </button>
                ))}
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
