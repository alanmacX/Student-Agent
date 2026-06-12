import { useState, useEffect, useCallback } from "react";
import { Plus, Trash2, Edit2, RefreshCw, Check, ChevronDown, ChevronUp, Wifi } from "lucide-react";
import { apiFetch } from "../../api/client";

async function listProviders() {
  const d = await apiFetch("/api/providers");
  return [...(d.builtin || []), ...(d.custom || [])];
}

async function saveProvider(data) {
  if (data.id && data._exists) {
    return apiFetch(`/api/providers/${data.id}`, { method: "PATCH", body: JSON.stringify(data) });
  }
  return apiFetch("/api/providers", { method: "POST", body: JSON.stringify(data) });
}

async function deleteProvider(id) {
  return apiFetch(`/api/providers/${id}`, { method: "DELETE" });
}

async function fetchModels(providerId, base_url, api_key) {
  return apiFetch(`/api/providers/${providerId || "new"}/fetch-models`, {
    method: "POST",
    body: JSON.stringify({ base_url, api_key }),
  });
}

const EMPTY_FORM = { name: "", base_url: "", api_key: "", models: [] };

export default function ProviderSettings() {
  const [providers, setProviders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editingId, setEditingId] = useState(null);
  const [form, setForm] = useState(EMPTY_FORM);
  const [fetchingModels, setFetchingModels] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reachability, setReachability] = useState({});
  const [scheduleProviderId, setScheduleProviderId] = useState("xiaomimimo");
  const [lightProviderId, setLightProviderId] = useState("xiaomimimo");
  const [lightModel, setLightModel] = useState("");
  const [filterProviderId, setFilterProviderId] = useState("xiaomimimo");
  const [filterModel, setFilterModel] = useState("");

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const list = await listProviders();
      setProviders(list);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
    apiFetch("/api/settings").then((s) => {
      const scheduleDefault = s.schedule_agent_provider_id || "xiaomimimo";
      setScheduleProviderId(scheduleDefault);
      setLightProviderId(s.light_agent_provider_id || scheduleDefault);
      setLightModel(s.light_agent_model || "");
      setFilterProviderId(s.filter_provider || scheduleDefault);
      setFilterModel(s.filter_model || "");
    }).catch(() => {});
  }, [reload]);

  const startEdit = (provider) => {
    setEditingId(provider.id);
    setForm({ ...provider, api_key: "", api_key_placeholder: provider.api_key || "", _exists: true });
  };

  const startAdd = () => {
    setEditingId("new");
    setForm(EMPTY_FORM);
  };

  const cancelEdit = () => {
    setEditingId(null);
    setForm(EMPTY_FORM);
  };

  const handleFetchModels = async () => {
    setFetchingModels(true);
    try {
      const result = await fetchModels(form.id, form.base_url, form.api_key);
      if (result.models?.length) {
        setForm((f) => ({ ...f, models: result.models }));
      } else {
        alert(result.error || "未获取到模型列表");
      }
    } finally {
      setFetchingModels(false);
    }
  };

  const handleSave = async () => {
    if (!form.name || !form.base_url) return;
    setSaving(true);
    try {
      await saveProvider(form);
      await reload();
      cancelEdit();
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id) => {
    if (!confirm("确认删除此 Provider？")) return;
    await deleteProvider(id);
    await reload();
  };

  const handleCheckReachability = async (p) => {
    setReachability((r) => ({ ...r, [p.id]: "checking" }));
    try {
      const result = await apiFetch(`/api/providers/${p.id}/reachability`);
      setReachability((r) => ({ ...r, [p.id]: result.reachable ? "ok" : "fail" }));
    } catch {
      setReachability((r) => ({ ...r, [p.id]: "fail" }));
    }
  };

  const saveScheduleProvider = async (id) => {
    setScheduleProviderId(id);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { schedule_agent_provider_id: id } }),
    });
  };

  const saveLightProvider = async (id) => {
    setLightProviderId(id);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { light_agent_provider_id: id } }),
    });
  };

  const saveLightModel = async () => {
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { light_agent_model: lightModel.trim() } }),
    });
  };

  const saveFilterProvider = async (id) => {
    setFilterProviderId(id);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { filter_provider: id } }),
    });
  };

  const saveFilterModel = async () => {
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { filter_model: filterModel.trim() } }),
    });
  };

  return (
    <div className="stagger max-w-2xl space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-white">API Providers</h2>
          <p className="mt-0.5 text-xs text-[var(--text-tertiary)]">
            添加 OpenAI 兼容接口。模型列表可自动从 /v1/models 获取。
          </p>
        </div>
        <button
          onClick={startAdd}
          className="flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-2xl bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white transition-all duration-200 ease-[var(--ease-spring)] hover:bg-[var(--accent-strong)] active:scale-95"
        >
          <Plus size={16} />
          添加
        </button>
      </div>

      {editingId === "new" && (
        <ProviderForm
          form={form}
          setForm={setForm}
          onFetchModels={handleFetchModels}
          fetchingModels={fetchingModels}
          onSave={handleSave}
          onCancel={cancelEdit}
          saving={saving}
          title="添加 Provider"
        />
      )}

      {loading ? (
        <p className="text-sm text-[var(--text-tertiary)]">加载中...</p>
      ) : (
        <div className="space-y-2">
          {providers.map((p) => (
            <div key={p.id}>
              <div className="ui-card ui-card-interactive flex items-center gap-3 px-3.5 py-3">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-white">{p.name}</p>
                  <p className="truncate text-xs text-[var(--text-tertiary)]">
                    {p.base_url} · {p.models?.[0] || "模型未配置"}
                    {p.models?.length > 1 && ` +${p.models.length - 1}`}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  {reachability[p.id] === "ok" && <Check size={14} className="text-green-400" />}
                  {reachability[p.id] === "fail" && <span className="text-xs text-red-400">✗</span>}
                  {reachability[p.id] === "checking" && <RefreshCw size={12} className="animate-spin text-[var(--text-tertiary)]" />}
                  <button
                    onClick={() => handleCheckReachability(p)}
                    className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
                    title="测试连接"
                  >
                    <Wifi size={14} />
                  </button>
                  <button
                    onClick={() => editingId === p.id ? cancelEdit() : startEdit(p)}
                    className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
                    title="编辑"
                  >
                    {editingId === p.id ? <ChevronUp size={14} /> : <Edit2 size={14} />}
                  </button>
                  {!p.is_builtin && (
                    <button
                      onClick={() => handleDelete(p.id)}
                      className="grid h-8 w-8 place-items-center rounded-full text-red-400/60 hover:bg-red-500/10 hover:text-red-400"
                      title="删除"
                    >
                      <Trash2 size={14} />
                    </button>
                  )}
                </div>
              </div>
              {editingId === p.id && (
                <div className="mt-1 rounded-2xl border border-[var(--accent)]/30 bg-[var(--surface)] p-3">
                  <ProviderForm
                    form={form}
                    setForm={setForm}
                    onFetchModels={handleFetchModels}
                    fetchingModels={fetchingModels}
                    onSave={handleSave}
                    onCancel={cancelEdit}
                    saving={saving}
                    title="编辑 Provider"
                    isBuiltin={p.is_builtin}
                  />
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      <div className="ui-card p-5 space-y-2">
        <p className="text-sm font-semibold text-white">Schedule Agent Provider</p>
        <select
          value={scheduleProviderId}
          onChange={(e) => saveScheduleProvider(e.target.value)}
          className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
        >
          {providers.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <p className="text-xs text-[var(--text-tertiary)]">
          日程 Agent 使用这个 Provider 处理对话。
        </p>
      </div>

      <div className="ui-card p-5 space-y-3">
        <div>
          <p className="text-sm font-semibold text-white">Light Router / Briefing Agent</p>
          <p className="mt-1 text-xs text-[var(--text-tertiary)]">
            用于工具清单选择和首页轻量 briefing；建议选快且便宜的模型，留空则用 Provider 默认模型。
          </p>
        </div>
        <select
          value={lightProviderId}
          onChange={(e) => saveLightProvider(e.target.value)}
          className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
        >
          {providers.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <div className="flex gap-2">
          <input
            value={lightModel}
            onChange={(e) => setLightModel(e.target.value)}
            onBlur={saveLightModel}
            placeholder="例如 gpt-4o-mini / qwen-flash；留空用默认"
            className="min-h-10 min-w-0 flex-1 rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none"
          />
          <button
            onClick={saveLightModel}
            className="rounded-2xl border border-[var(--border)] px-3 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            保存
          </button>
        </div>
      </div>

      <div className="ui-card p-5 space-y-3">
        <p className="text-sm font-semibold text-white">Filter Provider</p>
        <select
          value={filterProviderId}
          onChange={(e) => saveFilterProvider(e.target.value)}
          className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
        >
          {providers.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <div className="flex gap-2">
          <input
            value={filterModel}
            onChange={(e) => setFilterModel(e.target.value)}
            onBlur={saveFilterModel}
            placeholder="留空则用 provider 默认模型"
            className="min-h-10 min-w-0 flex-1 rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none"
          />
          <button
            onClick={saveFilterModel}
            className="rounded-2xl border border-[var(--border)] px-3 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            保存
          </button>
        </div>
      </div>
    </div>
  );
}

function ProviderForm({ form, setForm, onFetchModels, fetchingModels, onSave, onCancel, saving, title, isBuiltin }) {
  const f = (key) => (e) => setForm((prev) => ({ ...prev, [key]: e.target.value }));

  return (
    <div className="space-y-3">
      <p className="text-sm font-semibold text-[var(--text-secondary)]">{title}</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Provider 名称</span>
          <input
            value={form.name}
            onChange={f("name")}
            placeholder="我的 Provider"
            className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Base URL</span>
          <input
            value={form.base_url}
            onChange={f("base_url")}
            placeholder="https://api.example.com"
            disabled={isBuiltin}
            className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)] disabled:opacity-50"
          />
        </label>
      </div>
      <label className="block">
        <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">API Key</span>
        <input
          type="password"
          value={form.api_key}
          onChange={f("api_key")}
          placeholder={form.api_key_placeholder ? `留空保留 ${form.api_key_placeholder}` : "sk-..."}
          className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
      </label>

      <div>
        <div className="flex items-center justify-between mb-1">
          <span className="text-xs font-medium text-[var(--text-tertiary)]">
            模型列表 {form.models.length > 0 && `(${form.models.length} 个)`}
          </span>
          <button
            onClick={onFetchModels}
            disabled={fetchingModels || !form.base_url || (!form.api_key && !form._exists)}
            className="flex items-center gap-1 rounded-xl border border-[var(--border)] px-2 py-1 text-xs text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] disabled:opacity-40"
          >
            <RefreshCw size={11} className={fetchingModels ? "animate-spin" : ""} />
            自动获取
          </button>
        </div>
        <textarea
          value={form.models.join("\n")}
          onChange={(e) => setForm((f) => ({ ...f, models: e.target.value.split("\n").map((s) => s.trim()).filter(Boolean) }))}
          placeholder="每行一个模型 ID，或点击自动获取"
          rows={3}
          className="w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-xs text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
      </div>

      <div className="flex gap-2">
        <button
          onClick={onSave}
          disabled={saving || !form.name || !form.base_url}
          className="rounded-2xl bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-50"
        >
          {saving ? "保存中..." : "保存"}
        </button>
        <button
          onClick={onCancel}
          className="rounded-2xl border border-[var(--border)] px-4 py-2 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
        >
          取消
        </button>
      </div>
    </div>
  );
}
