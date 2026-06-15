import { useState, useEffect, useCallback } from "react";
import { Plus, Trash2, Edit2, RefreshCw, Check, ChevronUp, Wifi, Calculator } from "lucide-react";
import { apiFetch } from "../../api/client";
import { useCurrency, formatCost } from "../../lib/currency";

const DEEPSEEK_PRICING = {
  "deepseek-v4-flash": {
    label: "V4 Flash",
    cacheHit: 0.0028,
    cacheMiss: 0.14,
    output: 0.28,
    note: "默认推荐：路由、briefing、日常查询",
  },
  "deepseek-v4-pro": {
    label: "V4 Pro",
    cacheHit: 0.003625,
    cacheMiss: 0.435,
    output: 0.87,
    note: "复杂推理、长上下文、重要 agent 任务",
  },
};

const THINKING_MODES = [
  { id: "disabled", title: "快 / 省钱", detail: "non-thinking，适合日常查询；路由与 briefing 始终使用此模式。" },
  { id: "high", title: "稳", detail: "thinking high，适合复杂排查、跨表推理。" },
  { id: "max", title: "深推理", detail: "thinking max，留给高价值复杂 agent 任务。" },
];

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

const EMPTY_FORM = { name: "", base_url: "", api_key: "", api_type: "openAICompatible", models: [] };

export default function ProviderSettings() {
  useCurrency(); // re-render the cost estimator when currency/rate changes
  const [providers, setProviders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editingId, setEditingId] = useState(null);
  const [form, setForm] = useState(EMPTY_FORM);
  const [fetchingModels, setFetchingModels] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reachability, setReachability] = useState({});
  const [scheduleProviderId, setScheduleProviderId] = useState("xiaomimimo");
  const [scheduleModel, setScheduleModel] = useState("");
  const [lightProviderId, setLightProviderId] = useState("xiaomimimo");
  const [lightModel, setLightModel] = useState("");
  const [filterProviderId, setFilterProviderId] = useState("xiaomimimo");
  const [filterModel, setFilterModel] = useState("");
  const [deepseekThinking, setDeepseekThinking] = useState("disabled");
  const [deepseekUserId, setDeepseekUserId] = useState("student-agent");
  const [costModel, setCostModel] = useState("deepseek-v4-flash");
  const [costInputs, setCostInputs] = useState({ hit: "20000", miss: "5000", output: "1200" });

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
      setScheduleModel(s.schedule_agent_model || "");
      setLightProviderId(s.light_agent_provider_id || scheduleDefault);
      setLightModel(s.light_agent_model || "");
      setFilterProviderId(s.filter_provider || scheduleDefault);
      setFilterModel(s.filter_model || "");
      setDeepseekThinking(s.deepseek_agent_thinking || "disabled");
      setDeepseekUserId(s.deepseek_user_id || "student-agent");
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

  const providerById = useCallback(
    (id) => providers.find((p) => p.id === id) || providers[0] || null,
    [providers],
  );

  const firstModelFor = useCallback(
    (id) => providerById(id)?.models?.[0] || "",
    [providerById],
  );

  const handleFetchModels = async () => {
    setFetchingModels(true);
    try {
      const result = await apiFetch(`/api/providers/${form.id || "new"}/fetch-models`, {
        method: "POST",
        body: JSON.stringify({ base_url: form.base_url, api_key: form.api_key, api_type: form.api_type }),
      });
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
    const nextModel = firstModelFor(id);
    setScheduleProviderId(id);
    setScheduleModel(nextModel);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { schedule_agent_provider_id: id, schedule_agent_model: nextModel } }),
    });
  };

  const saveScheduleModel = async (value) => {
    setScheduleModel(value);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { schedule_agent_model: value } }),
    });
  };

  const saveLightProvider = async (id) => {
    const nextModel = firstModelFor(id);
    setLightProviderId(id);
    setLightModel(nextModel);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { light_agent_provider_id: id, light_agent_model: nextModel } }),
    });
  };

  const saveLightModel = async (value) => {
    setLightModel(value);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { light_agent_model: value } }),
    });
  };

  const saveFilterProvider = async (id) => {
    const nextModel = firstModelFor(id);
    setFilterProviderId(id);
    setFilterModel(nextModel);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { filter_provider: id, filter_model: nextModel } }),
    });
  };

  const saveFilterModel = async (value) => {
    setFilterModel(value);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { filter_model: value } }),
    });
  };

  const saveDeepseekThinking = async (value) => {
    setDeepseekThinking(value);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { deepseek_agent_thinking: value } }),
    });
  };

  const saveDeepseekUserId = async () => {
    const cleaned = (deepseekUserId || "student-agent").trim() || "student-agent";
    setDeepseekUserId(cleaned);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { deepseek_user_id: cleaned } }),
    });
  };

  const pricing = DEEPSEEK_PRICING[costModel] || DEEPSEEK_PRICING["deepseek-v4-flash"];
  const hitTokens = Math.max(0, Number(costInputs.hit) || 0);
  const missTokens = Math.max(0, Number(costInputs.miss) || 0);
  const outputTokens = Math.max(0, Number(costInputs.output) || 0);
  const estimatedCost = (
    hitTokens * pricing.cacheHit +
    missTokens * pricing.cacheMiss +
    outputTokens * pricing.output
  ) / 1_000_000;
  const cacheSavings = missTokens + hitTokens > 0
    ? (hitTokens * (pricing.cacheMiss - pricing.cacheHit)) / 1_000_000
    : 0;

  return (
    <div className="stagger max-w-2xl space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-white">API Providers</h2>
          <p className="mt-0.5 text-xs text-[var(--text-tertiary)]">
            添加 OpenAI 兼容接口。模型列表可按 Provider 类型自动获取。
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

      <AgentModelCard
        title="Schedule Agent"
        description="处理日程对话、数据库工具调用和写操作确认。"
        providers={providers}
        providerId={scheduleProviderId}
        model={scheduleModel}
        onProviderChange={saveScheduleProvider}
        onModelChange={saveScheduleModel}
      />

      <AgentModelCard
        title="Light Router / Briefing"
        description="工具清单选择和首页 briefing。建议用 DeepSeek V4 Flash 这类低延迟模型。"
        providers={providers}
        providerId={lightProviderId}
        model={lightModel}
        onProviderChange={saveLightProvider}
        onModelChange={saveLightModel}
      />

      <AgentModelCard
        title="Filter"
        description="钉钉/学习通过滤与轻量分类。优先选便宜、稳定、速度快的模型。"
        providers={providers}
        providerId={filterProviderId}
        model={filterModel}
        onProviderChange={saveFilterProvider}
        onModelChange={saveFilterModel}
      />

      <div className="ui-card p-5 space-y-3">
        <div>
          <p className="text-sm font-semibold text-white">DeepSeek Optimizations</p>
          <p className="mt-1 text-xs text-[var(--text-tertiary)]">
            路由和 briefing 固定 non-thinking；主 Agent 可按任务价值开启 thinking。花费按 cache hit / cache miss / output 分开计算。
          </p>
        </div>
        <div className="grid gap-2 sm:grid-cols-3">
          {THINKING_MODES.map((mode) => (
            <button
              key={mode.id}
              onClick={() => saveDeepseekThinking(mode.id)}
              className={`min-h-[94px] rounded-2xl border px-3 py-2 text-left transition ${
                deepseekThinking === mode.id
                  ? "border-[var(--accent)] bg-[var(--accent)]/12 text-white"
                  : "border-[var(--border)] bg-[var(--surface-2)] text-[var(--text-secondary)] hover:border-[var(--accent)]/60"
              }`}
            >
              <span className="block text-sm font-semibold">{mode.title}</span>
              <span className="mt-1 block text-xs leading-5 text-[var(--text-tertiary)]">{mode.detail}</span>
            </button>
          ))}
        </div>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">DeepSeek user_id</span>
          <div className="flex gap-2">
            <input
              value={deepseekUserId}
              onChange={(e) => setDeepseekUserId(e.target.value)}
              onBlur={saveDeepseekUserId}
              placeholder="student-agent"
              className="min-h-10 min-w-0 flex-1 rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none"
            />
            <button
              onClick={saveDeepseekUserId}
              className="rounded-2xl border border-[var(--border)] px-3 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
            >
              保存
            </button>
          </div>
          <p className="mt-1 text-xs text-[var(--text-tertiary)]">只能包含字母、数字、短横线和下划线；不要填真实身份信息。</p>
        </label>

        <div className="space-y-3 border-t border-[var(--border)] pt-4">
          <div className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-2">
              <Calculator size={15} className="text-[var(--accent)]" />
              <p className="text-sm font-semibold text-white">DeepSeek 花费估算</p>
            </div>
            <CurrencyToggle />
          </div>
          <div className="grid gap-2 sm:grid-cols-4">
            <label className="block sm:col-span-1">
              <span className="mb-1 block text-xs text-[var(--text-tertiary)]">模型</span>
              <select
                value={costModel}
                onChange={(e) => setCostModel(e.target.value)}
                className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
              >
                {Object.entries(DEEPSEEK_PRICING).map(([model, data]) => (
                  <option key={model} value={model}>{data.label}</option>
                ))}
              </select>
            </label>
            <CostInput label="Cache hit" value={costInputs.hit} onChange={(value) => setCostInputs((prev) => ({ ...prev, hit: value }))} />
            <CostInput label="Cache miss" value={costInputs.miss} onChange={(value) => setCostInputs((prev) => ({ ...prev, miss: value }))} />
            <CostInput label="Output" value={costInputs.output} onChange={(value) => setCostInputs((prev) => ({ ...prev, output: value }))} />
          </div>
          <div className="grid gap-2 sm:grid-cols-3">
            <Metric label="估算费用" value={formatCost(estimatedCost, 6)} tone="text-yellow-300" />
            <Metric label="缓存节省" value={formatCost(cacheSavings, 6)} tone="text-emerald-300" />
            <Metric label="模型定位" value={pricing.note} tone="text-white" />
          </div>
          <div className="grid gap-1.5 text-xs text-[var(--text-tertiary)]">
            {Object.entries(DEEPSEEK_PRICING).map(([model, data]) => (
              <p key={model}>
                <span className="text-[var(--text-secondary)]">{data.label}</span>
                {" "}hit ${data.cacheHit}/1M · miss ${data.cacheMiss}/1M · output ${data.output}/1M
              </p>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function AgentModelCard({ title, description, providers, providerId, model, onProviderChange, onModelChange }) {
  const provider = providers.find((p) => p.id === providerId) || providers[0] || {};
  const models = provider.models || [];
  const effectiveModel = model || models[0] || "";
  const hasLegacyModel = effectiveModel && !models.includes(effectiveModel);

  return (
    <div className="ui-card p-5 space-y-3">
      <div>
        <p className="text-sm font-semibold text-white">{title}</p>
        <p className="mt-1 text-xs text-[var(--text-tertiary)]">{description}</p>
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Provider</span>
          <select
            value={providerId}
            onChange={(e) => onProviderChange(e.target.value)}
            className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
          >
            {providers.map((p) => (
              <option key={p.id} value={p.id}>{p.name}</option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Model</span>
          <select
            value={effectiveModel}
            onChange={(e) => onModelChange(e.target.value)}
            disabled={!models.length && !hasLegacyModel}
            className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none disabled:opacity-50"
          >
            {!models.length && <option value="">先获取模型列表</option>}
            {hasLegacyModel && <option value={effectiveModel}>{effectiveModel}</option>}
            {models.map((m) => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
        </label>
      </div>
      <p className="text-xs text-[var(--text-tertiary)]">
        当前：{provider.name || "Provider"} / <span className="text-[var(--text-secondary)]">{effectiveModel || "未配置模型"}</span>
      </p>
    </div>
  );
}

function CostInput({ label, value, onChange }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs text-[var(--text-tertiary)]">{label}</span>
      <input
        type="number"
        min="0"
        inputMode="numeric"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
      />
    </label>
  );
}

function Metric({ label, value, tone }) {
  return (
    <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface-2)] px-3 py-2">
      <p className="text-[10px] uppercase tracking-wide text-[var(--text-tertiary)]">{label}</p>
      <p className={`mt-1 text-sm font-semibold tabular-nums ${tone}`}>{value}</p>
    </div>
  );
}

// Currency switcher — controls how all cost figures display (¥ vs $). Costs are
// always computed in USD; CNY just multiplies by an editable exchange rate.
function CurrencyToggle() {
  const { currency, rate, setCurrency, setRate } = useCurrency();
  return (
    <div className="flex items-center gap-2">
      <div className="flex rounded-full border border-[var(--border)] bg-[var(--surface-2)] p-0.5">
        {["CNY", "USD"].map((c) => (
          <button
            key={c}
            onClick={() => setCurrency(c)}
            className={`rounded-full px-2.5 py-1 text-xs font-medium transition-colors ${
              currency === c ? "bg-[var(--accent)] text-white" : "text-[var(--text-tertiary)] hover:text-white"
            }`}
          >
            {c === "CNY" ? "¥ 人民币" : "$ 美元"}
          </button>
        ))}
      </div>
      {currency === "CNY" && (
        <label className="flex items-center gap-1 text-xs text-[var(--text-tertiary)]">
          汇率
          <input
            type="number"
            step="0.1"
            min="0"
            value={rate}
            onChange={(e) => setRate(e.target.value)}
            className="w-16 rounded-lg border border-[var(--border)] bg-[var(--input-bg)] px-2 py-1 text-xs text-white focus:outline-none"
          />
        </label>
      )}
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
        <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">API 类型</span>
        <select
          value={form.api_type || "openAICompatible"}
          onChange={(e) => setForm((prev) => ({ ...prev, api_type: e.target.value }))}
          className="min-h-10 w-full rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        >
          <option value="openAICompatible">OpenAI Compatible</option>
          <option value="deepseek">DeepSeek</option>
          <option value="xiaomiMimo">小米 MiMo</option>
          <option value="anthropic">Anthropic</option>
          <option value="gemini">Gemini</option>
        </select>
      </label>
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
