import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    let conversationID: UUID?
    let isFloating: Bool
    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 40
    @State private var isRefreshingModels = false
    @State private var modelRefreshStatus: String?
    @State private var showPersonaEditor = false

    init(conversationID: UUID? = nil, isFloating: Bool = false) {
        self.conversationID = conversationID
        self.isFloating = isFloating
    }

    private var conv: Conversation? {
        if let conversationID {
            return viewModel.conversations.first { $0.id == conversationID }
        }
        return viewModel.selectedConversation
    }

    private var isThisConversationStreaming: Bool {
        guard let id = conv?.id else { return false }
        return viewModel.isStreaming && viewModel.chatStreamingConversationID == id
    }

    var body: some View {
        Group {
            if conv == nil {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("对话不存在")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let conv, !isFloating, viewModel.isConversationFloating(conv.id) {
                floatingPlaceholder(conv)
            } else if isFloating {
                VStack(spacing: 0) {
                    if let conv = conv { floatingModelBar(conv) }
                    Divider()
                    messageList
                }
            } else {
                messageList
                    .toolbar {
                        if let conv = conv { chatToolbar(conv) }
                    }
            }
        }
        .navigationTitle(conv?.title ?? "对话")
        .navigationSubtitle(conv.map { "\(viewModel.provider(for: $0.providerID).name) · \($0.model)" } ?? "")
        .background(.windowBackground)
        .sheet(isPresented: $showPersonaEditor) {
            if let conv {
                ConversationPersonaSheet(conversationID: conv.id)
                    .environmentObject(viewModel)
            }
        }
    }

    private func floatingPlaceholder(_ conv: Conversation) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("这个对话已在浮动小窗中打开")
                .font(.headline)
            Text(conv.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                FloatingChatWindowManager.shared.close(conversationID: conv.id)
            } label: {
                Label("回到主窗口", systemImage: "arrow.down.left.and.arrow.up.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    // MARK: - Model bar

    @ToolbarContentBuilder
    private func chatToolbar(_ conv: Conversation) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(viewModel.allProviders) { p in
                    Button { viewModel.updateProvider(p.id, for: conv.id) } label: {
                        Label(p.name, systemImage: p.iconName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.provider(for: conv.providerID).iconName)
                    Text(viewModel.provider(for: conv.providerID).name).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Provider")
            
            Menu {
                ForEach(viewModel.availableModels(for: viewModel.provider(for: conv.providerID)), id: \.self) { m in
                    Button { viewModel.updateModel(m, for: conv.id) } label: {
                        Text(m)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(conv.model).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")

            Button(action: refreshCurrentProviderModels) {
                if isRefreshingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新模型列表", systemImage: "arrow.clockwise")
                }
            }
            .help("自动拉取当前 Provider 的模型列表")
            .disabled(isRefreshingModels)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !viewModel.isRoleplayMode {
                Menu {
                    ForEach(ChatAgentMode.allCases) { mode in
                        Button { viewModel.updateAgentMode(mode, for: conv.id) } label: {
                            Label(mode.title, systemImage: mode.iconName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: conv.agentMode.iconName)
                        Text(conv.agentMode.title).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("对话 Agent 模式")
            }

            toolsMenu
            
            roleplayToggle

            Button(action: { showPersonaEditor = true }) {
                Label("编辑人设", systemImage: "person.text.rectangle")
            }
            .help("编辑此对话的人设")
            
            Button(action: { FloatingChatWindowManager.shared.show(conversationID: conv.id, viewModel: viewModel) }) {
                Label("独立窗口", systemImage: "macwindow")
            }
            .help("缩成浮动小窗")

            Button(action: { viewModel.clearMessages(for: conv.id) }) {
                Label("清空对话", systemImage: "trash")
            }
            .help("清空对话 (⌘⇧K)")
        }
        
        ToolbarItem(placement: .navigation) {
            ContextWindowPill(stats: viewModel.contextWindowStats(for: conv))
        }
        
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 8) {
                let total = conv.totalUsage
                if total.totalTokens > 0 {
                    ConversationUsageBar(usage: total, model: conv.model)
                }
                if let modelRefreshStatus {
                    Text(modelRefreshStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var roleplayToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isRoleplayMode },
            set: { enabled in
                viewModel.isRoleplayMode = enabled
                viewModel.saveSettings()
            }
        )) {
            Image(systemName: "theatermasks")
        }
        .toggleStyle(.button)
        .help("开启后纯净无 Agent 参与，没有普通/Sub/Multi 可选")
    }

    private func floatingModelBar(_ conv: Conversation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(conv.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(viewModel.provider(for: conv.providerID).name) · \(conv.model)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isThisConversationStreaming {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                showPersonaEditor = true
            } label: {
                Image(systemName: "person.text.rectangle")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("编辑此对话的人设")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var toolsMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { viewModel.deepThinkingEnabled },
                set: { enabled in
                    viewModel.deepThinkingEnabled = enabled
                    if !enabled { viewModel.showReasoningSummary = false }
                    viewModel.saveSettings()
                }
            )) {
                Label("深度思考", systemImage: "brain.head.profile")
            }

            Toggle(isOn: Binding(
                get: { viewModel.showReasoningSummary },
                set: { enabled in
                    viewModel.showReasoningSummary = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("显示思考摘要", systemImage: "text.bubble")
            }
            .disabled(!viewModel.deepThinkingEnabled)

            Divider()

            Toggle(isOn: Binding(
                get: { viewModel.webAccessEnabled },
                set: { enabled in
                    viewModel.webAccessEnabled = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("联网工具", systemImage: viewModel.webAccessEnabled ? "network" : "network.slash")
            }
            Text("只访问公共 http/https，阻止本机和内网。")
                .font(.caption)

            Divider()

            Toggle(isOn: Binding(
                get: { viewModel.scheduleModeEnabled },
                set: { enabled in
                    viewModel.scheduleModeEnabled = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("日程模式", systemImage: viewModel.scheduleModeEnabled ? "calendar.badge.clock" : "calendar")
            }
            Text("开启后才允许普通聊天读取或修改日历、提醒事项、课程表和学习通。")
                .font(.caption)

            Divider()

            Toggle(isOn: Binding(
                get: { viewModel.pdfToolEnabled },
                set: { enabled in
                    viewModel.pdfToolEnabled = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("PDF 工具", systemImage: viewModel.pdfToolEnabled ? "doc.richtext.fill" : "doc.richtext")
            }
            Text("只读取你明确给出路径的本地 PDF。")
                .font(.caption)

            Toggle(isOn: Binding(
                get: { viewModel.appleNotesToolEnabled },
                set: { enabled in
                    viewModel.appleNotesToolEnabled = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("Apple Notes 工具", systemImage: viewModel.appleNotesToolEnabled ? "note.text" : "note")
            }
            Text("允许通过系统自动化搜索/读取或创建备忘录。")
                .font(.caption)

            Toggle(isOn: Binding(
                get: { viewModel.shoppingListToolEnabled },
                set: { enabled in
                    viewModel.shoppingListToolEnabled = enabled
                    viewModel.saveSettings()
                }
            )) {
                Label("购物清单工具", systemImage: viewModel.shoppingListToolEnabled ? "cart.fill" : "cart")
            }
            Text("维护 App 内持久化购物清单。")
                .font(.caption)

            Divider()

            if viewModel.chatSkills.isEmpty {
                Button {
                    openSettings()
                } label: {
                    Label("导入 Skill 文件夹", systemImage: "folder.badge.plus")
                }
            } else {
                ForEach(viewModel.chatSkills) { skill in
                    Toggle(isOn: Binding(
                        get: { viewModel.chatSkills.first(where: { $0.id == skill.id })?.isEnabled ?? false },
                        set: { viewModel.setChatSkill(skill.id, isEnabled: $0) }
                    )) {
                        Text(skill.name)
                    }
                }
                Divider()
                Button {
                    openSettings()
                } label: {
                    Label("管理 Skills", systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            Label("工具", systemImage: "switch.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("联网和 Skills")
    }

    private func agentModePicker(_ conv: Conversation) -> some View {
        Picker("Agent", selection: Binding(
            get: { conv.agentMode },
            set: { mode in
                viewModel.updateAgentMode(mode, for: conv.id)
            }
        )) {
            ForEach(ChatAgentMode.allCases) { mode in
                Label(mode.title, systemImage: mode.iconName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 184)
        .help("这个对话自己的普通 / Multi-agent / Sub-agent 模式")
    }

    private func refreshCurrentProviderModels() {
        guard let conv else { return }
        isRefreshingModels = true
        modelRefreshStatus = nil
        Task {
            do {
                let models = try await viewModel.refreshModels(for: conv.providerID)
                await MainActor.run {
                    modelRefreshStatus = "已更新 \(models.count) 个模型"
                    isRefreshingModels = false
                }
            } catch {
                await MainActor.run {
                    modelRefreshStatus = "模型拉取失败：\(error.localizedDescription)"
                    isRefreshingModels = false
                }
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let messages = conv?.messages {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    if isThisConversationStreaming {
                        HStack(spacing: 8) {
                            TypingIndicator()
                            if !viewModel.activeToolStatus.isEmpty {
                                Text(viewModel.activeToolStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            } else if viewModel.isChatThinking {
                                Text("思考中...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.leading, 12)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let err = viewModel.errorMessage { errorBanner(err) }
                    chatToolConfirmationPanel
                    agentVisualizationPanel
                    inputBar
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 8)
            }
            .onChange(of: conv?.messages.count) { scroll(proxy) }
            .onChange(of: conv?.messages.last?.content) { scroll(proxy) }
            .onAppear { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.scrollEase) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
            Text(msg).font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.quickSpring) { viewModel.errorMessage = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.08))
        .transition(.opacity.combined(with: .push(from: .top)))
        .animation(.quickSpring, value: viewModel.errorMessage != nil)
    }

    @ViewBuilder
    private var chatToolConfirmationPanel: some View {
        if let confirmation = viewModel.pendingChatToolConfirmation,
           confirmation.conversationID == conv?.id {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(confirmation.title)
                            .font(.system(size: 12, weight: .bold))
                        Text(confirmation.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(confirmation.tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title)
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                            Text(tool.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(minWidth: 96, maxWidth: 170, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.orange.opacity(0.26), lineWidth: 1)
                        )
                    }
                }

                HStack {
                    Spacer()
                    Button("拒绝") {
                        viewModel.resolveChatToolConfirmation(approved: false)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button("允许") {
                        viewModel.resolveChatToolConfirmation(approved: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .cardShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(0.96)))
            .animation(.quickSpring, value: confirmation)
        }
    }

    @ViewBuilder
    private var agentVisualizationPanel: some View {
        if let visual = viewModel.chatAgentVisualization,
           visual.conversationID == conv?.id,
           visual.mode != .normal || isThisConversationStreaming {
            let visibleSteps = compactAgentSteps(visual)
            let hiddenCount = max(visual.steps.count - visibleSteps.count, 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: visual.mode.iconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text(visual.title)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    ProgressView(value: agentProgress(visual))
                        .frame(width: 60)
                        .controlSize(.small)
                    
                    Text(agentModeSummary(visual))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                HStack(spacing: 8) {
                    ForEach(visibleSteps) { step in
                        AgentStepChip(step: step)
                    }
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .help("已折叠 \(hiddenCount) 个已完成步骤")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .cardShadow()
            .frame(maxWidth: .infinity, alignment: .leading) // Align to the left but width fits content
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(0.96)))
            .animation(.quickSpring, value: visual)
        }
    }

    private func agentModeSummary(_ visual: ChatAgentVisualization) -> String {
        let done = visual.steps.filter { $0.status == .done }.count
        let failed = visual.steps.filter { $0.status == .failed }.count
        let running = visual.steps.filter { $0.status == .running }.count
        if failed > 0 { return "\(failed) 失败 · \(done) 完成" }
        if running > 0 { return "\(running) 运行中 · \(done) 完成" }
        return "\(done)/\(visual.steps.count) 完成"
    }

    private func agentProgress(_ visual: ChatAgentVisualization) -> Double {
        guard !visual.steps.isEmpty else { return 0 }
        let finished = visual.steps.filter { $0.status == .done || $0.status == .failed }.count
        return Double(finished) / Double(visual.steps.count)
    }

    private func compactAgentSteps(_ visual: ChatAgentVisualization) -> [ChatAgentVisualStep] {
        let active = visual.steps.filter { $0.status == .running || $0.status == .failed }
        let waiting = visual.steps.filter { $0.status == .waiting }
        if !active.isEmpty {
            return Array((active + waiting).prefix(5))
        }
        return Array(visual.steps.suffix(4))
    }

    // MARK: - Input bar

    @FocusState private var textFocused: Bool

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MessageInputField(
                text: $inputText,
                measuredHeight: $inputHeight,
                placeholder: "发送消息…（Return 发送，Shift+Return 换行）",
                isDisabled: false,
                onSubmit: submitMessage
            )
            .frame(height: inputHeight)
            .padding(.vertical, 12)
            .padding(.leading, 16)

            sendButton
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .floatingShadow()
    }

    private var sendButton: some View {
        Button {
            if isThisConversationStreaming { viewModel.cancelChatResponse() }
            else { submitMessage() }
        } label: {
            ZStack {
                Circle()
                    .fill(sendFillColor)
                    .frame(width: 36, height: 36)
                    .shadow(color: sendFillColor.opacity(0.32), radius: 5, x: 0, y: 2)
                    .animation(.quickSpring, value: sendFillColor)

                Image(systemName: isThisConversationStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: isThisConversationStreaming ? 11 : 14, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .animation(.quickSpring, value: isThisConversationStreaming)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .pressScaleEffect()
        .disabled((viewModel.isStreaming && !isThisConversationStreaming) ||
                  (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThisConversationStreaming))
    }

    private var sendFillColor: Color {
        if isThisConversationStreaming { return .red }
        if viewModel.isStreaming { return Color(.disabledControlTextColor).opacity(0.3) }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Color(.disabledControlTextColor).opacity(0.3)
            : .accentColor
    }

    private func submitMessage() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conv else { return }
        inputText = ""
        viewModel.startSendingMessage(text, conversationID: conv.id)
    }
}

private struct ContextWindowPill: View {
    let stats: ContextWindowStats

    private var tint: Color {
        switch stats.ratio {
        case 0..<0.65: return .secondary
        case 0..<0.82: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: stats.summarizedMessageCount > 0 ? "doc.text.magnifyingglass" : "text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
            Text("\(format(stats.estimatedTokens)) / \(format(stats.maxTokens))")
                .font(.caption2.monospacedDigit())
            if stats.summarizedMessageCount > 0 {
                Text("已压缩 \(stats.summarizedMessageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(helpText)
    }

    private var helpText: String {
        if stats.summarizedMessageCount > 0 {
            return "当前发送给模型的估算上下文 token。较早的 \(stats.summarizedMessageCount) 条消息已压缩成摘要，聊天记录没有删除。"
        }
        return "当前发送给模型的估算上下文 token。"
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

@MainActor
final class FloatingChatWindowManager {
    static let shared = FloatingChatWindowManager()

    private var panels: [UUID: NSPanel] = [:]
    private var delegates: [UUID: FloatingChatPanelDelegate] = [:]

    private init() {}

    func show(conversationID: UUID, viewModel: ChatViewModel) {
        if let panel = panels[conversationID] {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            viewModel.markConversationFloating(conversationID, isFloating: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "浮动聊天"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 320, height: 360)
        panel.setFrameAutosaveName("FloatingChat-\(conversationID.uuidString)")

        let delegate = FloatingChatPanelDelegate { [weak self, weak panel] in
            panel?.contentView = nil
            self?.panels[conversationID] = nil
            self?.delegates[conversationID] = nil
            viewModel.markConversationFloating(conversationID, isFloating: false)
        }
        delegates[conversationID] = delegate
        panel.delegate = delegate

        panel.contentView = NSHostingView(
            rootView: ChatView(conversationID: conversationID, isFloating: true)
                .environmentObject(viewModel)
        )

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 36,
                y: frame.maxY - size.height - 72
            ))
        }

        panels[conversationID] = panel
        viewModel.markConversationFloating(conversationID, isFloating: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(conversationID: UUID) {
        guard let panel = panels[conversationID] else { return }
        panel.close()
    }
}

private final class FloatingChatPanelDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct ConversationPersonaSheet: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    @State private var prompt = ""

    private var conversation: Conversation? {
        viewModel.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("对话人设")
                        .font(.headline)
                    Text(conversation?.title ?? "当前对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            PromptEditor(text: $prompt, minHeight: 220, locked: false)

            HStack {
                Button("恢复默认") {
                    prompt = viewModel.chatPersonaPrompt
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    viewModel.updateSystemPrompt(prompt, for: conversationID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let existing = conversation?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            prompt = existing.isEmpty ? viewModel.chatPersonaPrompt : (conversation?.systemPrompt ?? "")
        }
    }
}

private struct AgentStepChip: View {
    let step: ChatAgentVisualStep

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            VStack(alignment: .leading, spacing: 0) {
                Text(step.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(step.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(minWidth: 82, maxWidth: 132, alignment: .leading)
        .background(statusColor.opacity(step.status == .done ? 0.07 : 0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(statusColor.opacity(step.status == .done ? 0.22 : 0.42), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .waiting:
            Image(systemName: "circle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(statusColor)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .waiting: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Native message input

struct MessageInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    var placeholder: String
    var isDisabled: Bool
    var minHeight: CGFloat = 40
    var maxHeight: CGFloat = 140
    var onSubmit: () -> Void
    /// Called when ↑ is pressed — lets the parent navigate a suggestion menu.
    var onMoveUp: (() -> Void)? = nil
    /// Called when ↓ is pressed — lets the parent navigate a suggestion menu.
    var onMoveDown: (() -> Void)? = nil
    /// Called when Tab is pressed — lets the parent autocomplete a suggestion.
    var onTab: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = !isDisabled
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: max(scrollView.contentSize.width, 120), height: minHeight)
        )
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView.documentView = textView
        context.coordinator.recalculateHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let maxLocation = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selectedRange.location, maxLocation), length: 0))
        }
        textView.placeholder = placeholder
        textView.isEditable = !isDisabled
        textView.textColor = isDisabled ? .disabledControlTextColor : .labelColor
        textView.needsDisplay = true
        context.coordinator.recalculateHeight(for: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInputField

        init(_ parent: MessageInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            recalculateHeight(for: textView)
            scrollInsertionPointIntoView(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ↑ / ↓ — delegate to suggestion-menu navigation when provided
            if commandSelector == #selector(NSResponder.moveUp(_:)),
               let handler = parent.onMoveUp {
                handler(); return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)),
               let handler = parent.onMoveDown {
                handler(); return true
            }
            // Tab — autocomplete highlighted suggestion
            if commandSelector == #selector(NSResponder.insertTab(_:)),
               let handler = parent.onTab {
                handler(); return true
            }

            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            if textView.hasMarkedText() { return false }

            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                recalculateHeight(for: textView)
                scrollInsertionPointIntoView(textView)
                return true
            }

            parent.onSubmit()
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView else { return }
            recalculateHeight(for: textView)
            scrollInsertionPointIntoView(textView)
        }

        func recalculateHeight(for textView: NSTextView) {
            guard let container = textView.textContainer,
                  let layoutManager = textView.layoutManager,
                  let scrollView = textView.enclosingScrollView else { return }

            let width = max(scrollView.contentSize.width, 120)
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)

            let usedHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2 + 2
            let documentHeight = max(ceil(usedHeight), scrollView.contentSize.height, parent.minHeight)
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: documentHeight))
            }

            let nextHeight = min(max(ceil(usedHeight), parent.minHeight), parent.maxHeight)
            if abs(parent.measuredHeight - nextHeight) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.measuredHeight = nextHeight
                }
            }
        }

        private func scrollInsertionPointIntoView(_ textView: NSTextView) {
            guard textView.window?.firstResponder === textView else { return }
            let selectedRange = textView.selectedRange()
            textView.scrollRangeToVisible(NSRange(location: selectedRange.location, length: 0))
            if let scrollView = textView.enclosingScrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    final class PlaceholderTextView: NSTextView {
        var placeholder = "" {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraph
            ]
            let rect = NSRect(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerInset.height,
                width: bounds.width - textContainerInset.width * 2,
                height: 22
            )
            placeholder.draw(in: rect, withAttributes: attributes)
        }
    }
}

// MARK: - Typing indicator (PhaseAnimator — macOS 14+)

struct TypingIndicator: View {
    var body: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    TypingDot(delay: Double(i) * 0.18)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.controlBackgroundColor))
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: 18))
            .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
            Spacer()
        }
        .padding(.horizontal)
        .transition(
            .scale(0.82, anchor: .leading)
            .combined(with: .opacity)
            .combined(with: .blurReplace)
        )
    }
}

private struct TypingDot: View {
    let delay: Double

    var body: some View {
        PhaseAnimator([0.0, 1.0, 0.0], trigger: delay) { phase in
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
                .scaleEffect(1.0 + phase * 0.28)
                .offset(y: -phase * 4)
        } animation: { _ in
            .spring(duration: 0.46, bounce: 0.5).delay(delay)
        }
    }
}
