import { useEffect, useMemo, useState } from "react";
import { Plus, Trash2, MessageSquare, Search } from "lucide-react";
import { useConversations } from "../../hooks/useConversations";
import { fetchProviders } from "../../api/providers";
import { defaultModel, FALLBACK_PROVIDERS, mergeProviders, providerColor, providerMeta } from "../../lib/providers";

export default function Sidebar({ selectedId, onSelect, mobile = false }) {
  const { conversations, loading, create, remove } = useConversations();
  const [search, setSearch] = useState("");
  const [providers, setProviders] = useState(FALLBACK_PROVIDERS);

  useEffect(() => {
    fetchProviders()
      .then((data) => setProviders(mergeProviders(data)))
      .catch(() => {});
  }, []);

  const filtered = useMemo(
    () =>
      conversations.filter((c) =>
        c.title.toLowerCase().includes(search.toLowerCase())
      ),
    [conversations, search]
  );

  const handleNew = async (provider = providers[0]) => {
    const conv = await create({
      title: "新建对话",
      provider_id: provider.id,
      model: defaultModel(provider),
    });
    onSelect(conv.id);
  };

  const handleDelete = async (e, id) => {
    e.stopPropagation();
    await remove(id);
    if (selectedId === id) onSelect(null);
  };

  return (
    <aside
      className={`flex min-h-0 flex-col bg-[var(--sidebar-bg)] ${
        mobile
          ? "h-full"
          : "mr-3 w-72 rounded-[18px] border border-[var(--border)] shadow-2xl shadow-black/25"
      }`}
    >
      {/* Header */}
      <div className="border-b border-[var(--border)] p-3">
        <button
          onClick={() => handleNew()}
          className="flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-[var(--accent)] px-3 py-2.5 text-sm font-semibold text-white shadow-lg shadow-black/20 transition hover:bg-[var(--accent-strong)]"
        >
          <Plus size={16} />
          新建对话
        </button>
        <div className="mt-3 grid grid-cols-4 gap-2">
          {providers.slice(0, 4).map((provider) => (
            <button
              key={provider.id}
              onClick={() => handleNew(provider)}
              className="flex h-9 items-center justify-center rounded-lg border border-[var(--border)] bg-[var(--surface)] text-[11px] font-medium text-[var(--text-secondary)] transition hover:bg-[var(--hover-bg)]"
              title={`使用 ${provider.name}`}
            >
              <span
                className="mr-1.5 h-2 w-2 rounded-full"
                style={{ backgroundColor: providerColor(provider) }}
              />
              <span className="truncate">{provider.name.replace("小米 ", "")}</span>
            </button>
          ))}
        </div>
      </div>

      {/* Search */}
      <div className="px-3 py-3">
        <div className="flex min-h-10 items-center gap-2 rounded-xl border border-[var(--border)] bg-[var(--deep-bg)] px-3">
          <Search size={14} className="text-[var(--text-tertiary)]" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="搜索对话"
            className="min-w-0 flex-1 bg-transparent text-base text-white placeholder-[var(--text-tertiary)] focus:outline-none md:text-sm"
          />
        </div>
      </div>

      {/* List */}
      <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-3">
        {loading ? (
          <div className="p-3 text-sm text-[var(--text-tertiary)]">正在载入...</div>
        ) : filtered.length === 0 ? (
          <div className="p-3 text-sm text-[var(--text-tertiary)]">没有匹配的对话</div>
        ) : (
          filtered.map((conv) => {
            const provider = providerMeta(conv.provider_id, providers);
            return (
              <div
                key={conv.id}
                onClick={() => onSelect(conv.id)}
                className={`group mb-1 flex cursor-pointer items-center justify-between rounded-xl px-3 py-2.5 transition ${
                  selectedId === conv.id
                    ? "bg-[var(--hover-bg)] text-white"
                    : "text-[var(--text-secondary)] hover:bg-[var(--surface-2)] hover:text-white"
                }`}
              >
                <div className="flex min-w-0 items-center gap-2.5">
                  <span
                    className="grid h-7 w-7 flex-shrink-0 place-items-center rounded-lg bg-[var(--surface-2)]"
                    style={{ color: providerColor(provider) }}
                  >
                    <MessageSquare size={14} />
                  </span>
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{conv.title}</p>
                    <p className="truncate text-xs text-[var(--text-tertiary)]">
                      {provider.name} · {conv.model}
                    </p>
                  </div>
                </div>
                <button
                  onClick={(e) => handleDelete(e, conv.id)}
                  className="grid h-8 w-8 flex-shrink-0 place-items-center rounded-lg text-[var(--text-tertiary)] opacity-100 transition hover:bg-[var(--hover-bg)] hover:text-red-300 md:opacity-0 md:group-hover:opacity-100"
                  aria-label="删除对话"
                >
                  <Trash2 size={14} />
                </button>
              </div>
            );
          })
        )}
      </div>
    </aside>
  );
}
