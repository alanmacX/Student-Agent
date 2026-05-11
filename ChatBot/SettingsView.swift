import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    var body: some View {
        TabView {
            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
                .environmentObject(viewModel)
            CustomProvidersTab()
                .tabItem { Label("自定义接口", systemImage: "network") }
                .environmentObject(viewModel)
            PromptSettingsTab()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
                .environmentObject(viewModel)
            ChatSkillsTab()
                .tabItem { Label("Skills", systemImage: "wand.and.sparkles") }
                .environmentObject(viewModel)
            IntegrationsTab()
                .tabItem { Label("集成", systemImage: "puzzlepiece.fill") }
        }
        .frame(width: 680, height: 560)
    }
}

// MARK: - API Keys Tab

struct APIKeysTab: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var balanceProvider: Provider?
    @State private var checkingProviderID: String?
    @State private var reachabilityResults: [String: APIReachabilityResult] = [:]

    var body: some View {
        Form {
            Section("内置 Provider") {
                apiKeyRow(label: "OpenAI",        placeholder: "sk-…",     provider: .openAI,
                          value: Binding(get: { viewModel.openAIKey },
                                         set: { viewModel.openAIKey = $0; viewModel.saveSettings() }))
                apiKeyRow(label: "Anthropic",     placeholder: "sk-ant-…", provider: .anthropic,
                          value: Binding(get: { viewModel.anthropicKey },
                                         set: { viewModel.anthropicKey = $0; viewModel.saveSettings() }))
                apiKeyRow(label: "Google Gemini", placeholder: "AIza…",    provider: .gemini,
                          value: Binding(get: { viewModel.geminiKey },
                                         set: { viewModel.geminiKey = $0; viewModel.saveSettings() }))
                apiKeyRow(label: "小米 MiMo",      placeholder: "MIMO_API_KEY", provider: .xiaomiMimo,
                          value: Binding(get: { viewModel.mimoKey },
                                         set: { viewModel.mimoKey = $0; viewModel.saveSettings() }))
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $balanceProvider) { p in
            BalanceSheet(provider: p).environmentObject(viewModel)
        }
    }

    private func apiKeyRow(label: String, placeholder: String, provider: Provider,
                           value: Binding<String>) -> some View {
        providerReachabilityRow(provider: provider) {
            HStack {
                LabeledContent(label) {
                    SecureField(placeholder, text: value)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                }
                if provider.supportsBalanceCheck {
                    Button {
                        balanceProvider = provider
                    } label: {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("查询 \(label) 余额")
                    .disabled(value.wrappedValue.isEmpty)
                }
            }
        }
    }

    private func providerReachabilityRow<Content: View>(provider: Provider,
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                content()
                Spacer()
                Button {
                    runReachabilityCheck(provider)
                } label: {
                    if checkingProviderID == provider.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("检测 \(provider.name) API 可达性")
                .disabled(checkingProviderID != nil)
            }

            if let result = reachabilityResults[provider.id] {
                ReachabilityStatusView(result: result)
            }
        }
    }

    private func runReachabilityCheck(_ provider: Provider) {
        checkingProviderID = provider.id
        Task {
            let result = await viewModel.checkAPIReachability(for: provider)
            await MainActor.run {
                reachabilityResults[provider.id] = result
                checkingProviderID = nil
            }
        }
    }
}

// MARK: - Custom Providers Tab

struct CustomProvidersTab: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showAddSheet = false
    @State private var editingProvider: Provider?
    @State private var balanceProvider: Provider?
    @State private var checkingProviderID: String?
    @State private var refreshingModelProviderID: String?
    @State private var reachabilityResults: [String: APIReachabilityResult] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.customProviders.isEmpty {
                emptyState
            } else {
                providerList
            }
            Divider()
            HStack {
                Button { showAddSheet = true } label: {
                    Label("添加自定义接口", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Text("兼容 OpenAI Chat Completions API")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .sheet(isPresented: $showAddSheet) {
            EditProviderSheet(provider: nil) { name, url, key, models in
                viewModel.addCustomProvider(name: name, baseURL: url, apiKey: key, models: models)
            }
        }
        .sheet(item: $editingProvider) { p in
            EditProviderSheet(provider: p) { name, url, key, models in
                let list = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                var updated = p
                updated.name = name; updated.baseURL = url
                updated.customAPIKey = key
                updated.models = list.isEmpty ? p.models : list
                viewModel.updateCustomProvider(updated)
            }
        }
        .sheet(item: $balanceProvider) { p in
            BalanceSheet(provider: p).environmentObject(viewModel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("还没有自定义接口").foregroundStyle(.secondary)
            Text("可以添加 DeepSeek、Moonshot、本地 vLLM 等\n任何兼容 OpenAI 格式的 API")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providerList: some View {
        List {
            ForEach(viewModel.customProviders) { p in
                HStack(spacing: 12) {
                    Image(systemName: p.iconName)
                        .foregroundStyle(Color(hex: p.colorHex)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.callout.bold())
                        Text(p.baseURL).font(.caption).foregroundStyle(.secondary)
                        Text(p.models.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                        if let result = reachabilityResults[p.id] {
                            ReachabilityStatusView(result: result)
                        }
                    }
                    Spacer()

                    Button {
                        refreshModels(p)
                    } label: {
                        if refreshingModelProviderID == p.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("自动更新模型列表")
                    .disabled(refreshingModelProviderID != nil)

                    Button {
                        runReachabilityCheck(p)
                    } label: {
                        if checkingProviderID == p.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("检测 API 可达性")
                    .disabled(checkingProviderID != nil)

                    // Balance check button
                    Button {
                        balanceProvider = p
                    } label: {
                        Image(systemName: "creditcard").foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help("查询余额")
                    .disabled(p.customAPIKey.isEmpty)

                    Button("编辑") { editingProvider = p }
                        .buttonStyle(.borderless).foregroundStyle(.blue)

                    Button {
                        viewModel.deleteCustomProvider(p)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    private func runReachabilityCheck(_ provider: Provider) {
        checkingProviderID = provider.id
        Task {
            let result = await viewModel.checkAPIReachability(for: provider)
            await MainActor.run {
                reachabilityResults[provider.id] = result
                checkingProviderID = nil
            }
        }
    }

    private func refreshModels(_ provider: Provider) {
        refreshingModelProviderID = provider.id
        Task {
            do {
                _ = try await viewModel.refreshModels(for: provider.id)
                await MainActor.run {
                    refreshingModelProviderID = nil
                }
            } catch {
                await MainActor.run {
                    reachabilityResults[provider.id] = APIReachabilityResult(
                        state: .endpointIssue,
                        statusCode: nil,
                        latencyMS: 0,
                        message: "模型列表获取失败：\(error.localizedDescription)"
                    )
                    refreshingModelProviderID = nil
                }
            }
        }
    }
}

struct ReachabilityStatusView: View {
    let result: APIReachabilityResult

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(result.message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .font(.caption2)
    }

    private var iconName: String {
        switch result.state {
        case .reachable: return "checkmark.circle.fill"
        case .authIssue: return "key.slash.fill"
        case .endpointIssue: return "exclamationmark.triangle.fill"
        case .networkIssue: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch result.state {
        case .reachable: return .green
        case .authIssue, .endpointIssue: return .orange
        case .networkIssue: return .red
        }
    }
}

// MARK: - Prompt Settings Tab

struct PromptSettingsTab: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(viewModel.promptsLocked ? "Prompt 已锁定" : "Prompt 可编辑",
                          systemImage: viewModel.promptsLocked ? "lock.fill" : "lock.open.fill")
                    Spacer()
                    Button(viewModel.promptsLocked ? "解锁" : "锁定") {
                        viewModel.promptsLocked.toggle()
                        viewModel.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                PromptEditor(
                    text: Binding(
                        get: { viewModel.chatPersonaPrompt },
                        set: { viewModel.chatPersonaPrompt = $0; viewModel.saveSettings() }
                    ),
                    minHeight: 140,
                    locked: viewModel.promptsLocked
                )
                HStack {
                    Button("恢复默认") {
                        viewModel.chatPersonaPrompt = ChatViewModel.defaultChatPersonaPrompt
                        viewModel.saveSettings()
                    }
                    .disabled(viewModel.promptsLocked)
                    Spacer()
                    Button("清空") {
                        viewModel.chatPersonaPrompt = ""
                        viewModel.saveSettings()
                    }
                    .disabled(viewModel.promptsLocked || viewModel.chatPersonaPrompt.isEmpty)
                }
            } header: {
                Text("聊天人设 Prompt")
            }

            Section {
                PromptEditor(
                    text: Binding(
                        get: { viewModel.scheduleAgentPrompt },
                        set: { viewModel.scheduleAgentPrompt = $0; viewModel.saveSettings() }
                    ),
                    minHeight: 160,
                    locked: viewModel.promptsLocked
                )
                HStack {
                    Button("恢复默认") {
                        viewModel.scheduleAgentPrompt = ChatViewModel.defaultScheduleAgentPrompt
                        viewModel.saveSettings()
                    }
                    .disabled(viewModel.promptsLocked)
                    Spacer()
                    Button("清空") {
                        viewModel.scheduleAgentPrompt = ""
                        viewModel.saveSettings()
                    }
                    .disabled(viewModel.promptsLocked || viewModel.scheduleAgentPrompt.isEmpty)
                }
            } header: {
                Text("日程 Agent Prompt")
            }

            Section {
                Toggle("启用联网工具", isOn: Binding(
                    get: { viewModel.webAccessEnabled },
                    set: { enabled in
                        viewModel.webAccessEnabled = enabled
                        viewModel.saveSettings()
                    }
                ))
                Text("Chat 可调用 web_search / web_fetch 访问公共网页；本机、内网和本地文件会被阻止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("聊天联网")
            }

            Section {
                Toggle("保存后切到日程页", isOn: Binding(
                    get: { viewModel.quickCaptureOpenScheduleAfterSave },
                    set: { enabled in
                        viewModel.quickCaptureOpenScheduleAfterSave = enabled
                        viewModel.saveSettings()
                    }
                ))
                Toggle("发送给 Agent 时附带来源 App 和捕获时间", isOn: Binding(
                    get: { viewModel.quickCaptureIncludeSourceMetadata },
                    set: { enabled in
                        viewModel.quickCaptureIncludeSourceMetadata = enabled
                        viewModel.saveSettings()
                    }
                ))
                Toggle("发送后保留中转站条目", isOn: Binding(
                    get: { viewModel.quickCaptureKeepAfterSend },
                    set: { enabled in
                        viewModel.quickCaptureKeepAfterSend = enabled
                        viewModel.saveSettings()
                    }
                ))
                Text("全局快捷键：⌥Space。捕获内容会先进入中转站，可编辑后再交给日程 Agent。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("快速捕获")
            }

            Section {
                Toggle("启用 Multi-agent 模式", isOn: Binding(
                    get: { viewModel.multiAgentEnabled },
                    set: { enabled in
                        viewModel.multiAgentEnabled = enabled
                        viewModel.saveSettings()
                    }
                ))
                Text("工作逻辑：1. 当前会话 provider 一定参与；2. 追加最多 3 个已配置且可用的云端 provider；3. 各自独立生成候选草稿；4. 当前会话 provider 读取草稿并输出唯一 final result。候选草稿只放在思考区域，不混进最终回答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.multiAgentPlanDescription(active: viewModel.activeProvider))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Multi-agent")
            }

            Section {
                Picker("Agent 思考预算", selection: Binding(
                    get: { viewModel.agentThinkingBudgetTokens },
                    set: { viewModel.agentThinkingBudgetTokens = $0; viewModel.saveSettings() }
                )) {
                    Text("关闭").tag(0)
                    Text("低（1024 tokens）").tag(1024)
                    Text("中（4096 tokens）").tag(4096)
                    Text("高（8000 tokens）").tag(8000)
                    Text("最大（16000 tokens）").tag(16000)
                }
                Text("适用于日程 Agent（Anthropic 扩展思考）和 Chat Sub-agent。子 Agent 的预算不超过父 Agent。仅对支持 extended thinking 的 Anthropic 模型生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Agent 思考预算")
            }

            Section {
                Toggle("启用深度思考", isOn: Binding(
                    get: { viewModel.deepThinkingEnabled },
                    set: { enabled in
                        viewModel.deepThinkingEnabled = enabled
                        if !enabled { viewModel.showReasoningSummary = false }
                        viewModel.saveSettings()
                    }
                ))
                Toggle("显示思考摘要", isOn: Binding(
                    get: { viewModel.showReasoningSummary },
                    set: { enabled in
                        viewModel.showReasoningSummary = enabled
                        viewModel.saveSettings()
                    }
                ))
                .disabled(!viewModel.deepThinkingEnabled)
                Text("思考摘要只展示关键判断和取舍，不输出原始隐藏思维链。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("聊天推理")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PromptEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    let locked: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: minHeight)
                .padding(6)
                .background(Color(.textBackgroundColor).opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )
                .disabled(locked)

            if locked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }
}

// MARK: - Chat Skills Tab

struct ChatSkillsTab: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showAddSheet = false
    @State private var showSkillFolderImporter = false
    @State private var editingSkill: ChatSkill?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.chatSkills.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.chatSkills) { skill in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { viewModel.chatSkills.first(where: { $0.id == skill.id })?.isEnabled ?? false },
                                set: { viewModel.setChatSkill(skill.id, isEnabled: $0) }
                            ))
                            .labelsHidden()
                            .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                    .font(.callout.weight(.semibold))
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(skill.instructions)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                                if !skill.scripts.isEmpty {
                                    Label("\(skill.scripts.count) 个沙箱脚本", systemImage: "terminal")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }

                            Spacer()

                            Button("编辑") { editingSkill = skill }
                                .buttonStyle(.borderless)

                            Button {
                                viewModel.deleteChatSkill(skill)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        .padding(.vertical, 5)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    showSkillFolderImporter = true
                } label: {
                    Label("导入 Skill 文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showAddSheet = true
                } label: {
                    Label("手动文本 Skill", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("scripts/ 可联网沙箱运行；Chat 不能拿本地路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .fileImporter(
            isPresented: $showSkillFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importChatSkillFolder(from: url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EditSkillSheet(skill: nil) { name, description, instructions, enabled in
                viewModel.addChatSkill(name: name, description: description, instructions: instructions, isEnabled: enabled)
            }
        }
        .sheet(item: $editingSkill) { skill in
            EditSkillSheet(skill: skill) { name, description, instructions, enabled in
                var updated = skill
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.isEnabled = enabled
                viewModel.updateChatSkill(updated)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有 Chat Skills")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("导入包含 SKILL.md 的 Skill 文件夹；scripts/ 可在临时沙箱中运行并可联网。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: ChatSkill?
    let onSave: (String, String, String, Bool) -> Void

    @State private var name: String
    @State private var skillDescription: String
    @State private var instructions: String
    @State private var isEnabled: Bool

    init(skill: ChatSkill?, onSave: @escaping (String, String, String, Bool) -> Void) {
        self.skill = skill
        self.onSave = onSave
        _name = State(initialValue: skill?.name ?? "")
        _skillDescription = State(initialValue: skill?.description ?? "")
        _instructions = State(initialValue: skill?.instructions ?? "")
        _isEnabled = State(initialValue: skill?.isEnabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("名称") {
                        TextField("例如：code-review", text: $name)
                            .frame(width: 320)
                    }

                    LabeledContent("Description") {
                        TextField("描述能力以及何时使用", text: $skillDescription, axis: .vertical)
                            .lineLimit(2...4)
                            .frame(width: 320)
                    }

                    Toggle("默认启用", isOn: $isEnabled)
                } header: {
                    Text(skill == nil ? "新增 Skill" : "编辑 Skill")
                } footer: {
                    Text("手动新增只保存 instructions。要使用脚本，请导入包含 SKILL.md 和 scripts/ 的 Skill 文件夹。脚本可联网，但不能读取用户目录，写入仅限临时工作目录。")
                }

                Section("SKILL.md Instructions") {
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(6)
                        .background(Color(.textBackgroundColor).opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.18))
                        )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(name, skillDescription, instructions, isEnabled)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Edit Provider Sheet

struct EditProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let provider: Provider?
    let onSave: (String, String, String, String) -> Void

    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var models: String
    @State private var isFetchingModels = false
    @State private var modelFetchStatus: String?

    init(provider: Provider?, onSave: @escaping (String, String, String, String) -> Void) {
        self.provider = provider; self.onSave = onSave
        _name    = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseURL ?? "https://")
        _apiKey  = State(initialValue: provider?.customAPIKey ?? "")
        _models  = State(initialValue: provider?.models.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("名称")    { TextField("DeepSeek / Moonshot…", text: $name).frame(width: 260) }
                    LabeledContent("Base URL") { TextField("https://api.deepseek.com", text: $baseURL).frame(width: 260) }
                    LabeledContent("API Key")  { SecureField("留空则不发送 Authorization", text: $apiKey).frame(width: 260) }
                    LabeledContent("模型列表") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("可自动获取，也可手动输入", text: $models)
                                .frame(width: 260)
                            HStack(spacing: 8) {
                                if let modelFetchStatus {
                                    Text(modelFetchStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button {
                                    fetchModels()
                                } label: {
                                    if isFetchingModels {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("自动获取", systemImage: "arrow.clockwise")
                                    }
                                }
                                .disabled(isFetchingModels || !baseURL.hasPrefix("http"))
                            }
                        }
                    }
                } header: {
                    Text(provider == nil ? "新增自定义接口" : "编辑接口")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API 格式需兼容 OpenAI /v1/chat/completions")
                        Text("模型列表用英文逗号分隔 · 支持 /user/balance 余额查询")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button(provider == nil ? "添加" : "保存") {
                    onSave(name, baseURL, apiKey, models); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || !baseURL.hasPrefix("http"))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
        }
        .frame(width: 500, height: 430)
    }

    private func fetchModels() {
        isFetchingModels = true
        modelFetchStatus = nil
        let tempProvider = Provider(
            id: provider?.id ?? "custom-preview",
            name: name.isEmpty ? "Custom" : name,
            apiType: .openAICompatible,
            baseURL: baseURL,
            models: [],
            iconName: "network",
            colorHex: "6B7280",
            customAPIKey: apiKey
        )
        Task {
            do {
                let fetched = try await fetchProviderModels(provider: tempProvider, apiKey: apiKey)
                await MainActor.run {
                    models = fetched.joined(separator: ", ")
                    modelFetchStatus = "已获取 \(fetched.count) 个"
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    modelFetchStatus = "获取失败：\(error.localizedDescription)"
                    isFetchingModels = false
                }
            }
        }
    }
}

// MARK: - Integrations Tab

struct IntegrationsTab: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        Form {
            Section {
                ChaoxingStatusRow()
            } header: {
                Label("学习通", systemImage: "books.vertical.fill")
            } footer: {
                Text("登录后，日程助手可通过 get_chaoxing_assignments 工具获取你的作业列表和消息。")
                    .foregroundStyle(.secondary)
            }

            Section {
                ChaoxingMutedConversationsView()
            } header: {
                Label("屏蔽群聊", systemImage: "bell.slash")
            } footer: {
                Text("被屏蔽的群聊不会出现在 get_chaoxing_messages 结果中，也不会进入后台消息提取。名称精确匹配（不区分大小写）。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Chaoxing Muted Conversations

struct ChaoxingMutedConversationsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var newName = ""
    @FocusState private var fieldFocused: Bool

    private var sorted: [String] {
        viewModel.chaoxingMutedConversationNames.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sorted.isEmpty {
                Text("暂无屏蔽的群聊")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ForEach(sorted, id: \.self) { (name: String) in
                    HStack {
                        Image(systemName: "bell.slash.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(name)
                            .font(.callout)
                        Spacer()
                        Button {
                            viewModel.setChaoxingMuted(name, muted: false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .help("取消屏蔽")
                    }
                    .padding(.vertical, 1)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("输入群聊名称…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { addMuted() }
                Button("添加") { addMuted() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addMuted() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.setChaoxingMuted(trimmed, muted: true)
        newName = ""
        fieldFocused = true
    }
}
