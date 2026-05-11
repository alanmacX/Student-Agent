import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedTab: MainTab = .schedule
    @State private var balanceProvider: Provider?

    var body: some View {
        TabView(selection: $selectedTab) {
            ScheduleAgentView()
                .tabItem { Label("日程", systemImage: "calendar.badge.clock") }
                .tag(MainTab.schedule)
                .environmentObject(viewModel)

            chatTab
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(MainTab.chat)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.enableCompanionPet()
                    CompanionPetWindowManager.shared.show()
                } label: {
                    Image(systemName: "sparkles")
                }
                .help("显示 Codex 桌宠")
            }
            ToolbarItem(placement: .automatic) {
                balanceMenu
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gear")
                }
                .help("设置 (⌘,)")
            }
        }
        .sheet(item: $balanceProvider) { provider in
            BalanceSheet(provider: provider).environmentObject(viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            selectedTab = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScheduleAgent)) { _ in
            selectedTab = .schedule
        }
    }

    private var chatTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if viewModel.selectedConversation != nil {
                ChatView()
            } else {
                WelcomeView()
            }
        }
    }

    private var balanceMenu: some View {
        Menu {
            if let current = currentBalanceProvider {
                Button {
                    balanceProvider = current
                } label: {
                    Label("当前：\(current.name)", systemImage: current.iconName)
                }
                Divider()
            }

            if viewModel.balanceCheckProviders.isEmpty {
                Text("没有可查询余额的接口")
            } else {
                ForEach(viewModel.balanceCheckProviders) { provider in
                    Button {
                        balanceProvider = provider
                    } label: {
                        Label(provider.name, systemImage: provider.iconName)
                    }
                }
            }
        } label: {
            Image(systemName: "creditcard")
        }
        .help("快速查看余额")
    }

    private var currentBalanceProvider: Provider? {
        if viewModel.balanceCheckProviders.contains(where: { $0.id == viewModel.activeProvider.id }) {
            return viewModel.activeProvider
        }
        return viewModel.balanceCheckProviders.first
    }
}

private enum MainTab {
    case chat
    case schedule
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var appeared = false
    @State private var iconHovered = false

    var body: some View {
        ZStack {
            // Radial backdrop
            RadialGradient(
                colors: [Color.accentColor.opacity(0.07), .clear],
                center: .center, startRadius: 0, endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // Hero icon — floats on appear, gently lifts on hover
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.07)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 90, height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        )
                        .shadow(color: Color.accentColor.opacity(iconHovered ? 0.26 : 0.12),
                                radius: iconHovered ? 22 : 12, x: 0, y: iconHovered ? 10 : 4)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 40, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse, isActive: appeared)
                }
                .scaleEffect(appeared ? (iconHovered ? 1.06 : 1.0) : 0.65)
                .opacity(appeared ? 1 : 0)
                .animation(.bouncySpring, value: appeared)
                .animation(.quickSpring, value: iconHovered)
                .onHover { iconHovered = $0 }

                VStack(spacing: 6) {
                    Text("ChatBot")
                        .font(.largeTitle.bold())
                    Text("选择一个 API 开始对话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.uiSpring.delay(0.06), value: appeared)

                VStack(spacing: 9) {
                    ForEach(Array(viewModel.allProviders.enumerated()), id: \.element.id) { idx, provider in
                        ProviderButton(provider: provider, appeared: appeared, index: idx) {
                            viewModel.createConversation(providerID: provider.id)
                        }
                    }
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
        .onAppear {
            withAnimation(.uiSpring) { appeared = true }
        }
    }
}

// Extracted so each button can manage its own hover state
private struct ProviderButton: View {
    let provider: Provider
    let appeared: Bool
    let index: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(provider.name, systemImage: provider.iconName)
                .frame(width: 210)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(hex: provider.colorHex))
        .scaleEffect(hovered ? 1.03 : 1.0)
        .shadow(color: Color(hex: provider.colorHex).opacity(hovered ? 0.30 : 0),
                radius: 10, x: 0, y: 4)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.uiSpring.delay(Double(index) * 0.05 + 0.12), value: appeared)
        .animation(.quickSpring, value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Schedule Agent

struct ScheduleAgentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var chaoxingService = ChaoxingService.shared
    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 40
    @State private var showCSVImporter = false
    @State private var expandedScheduleDays: Set<String> = []
    @State private var didApplyScheduleDayDefaults = false
    @State private var isAgentChatExpanded = true
    @State private var isCaptureDockExpanded = false
    @State private var editingCapture: QuickCaptureItem?
    @State private var selectedSuggestionIdx: Int = 0
    // Cached message groups — avoids re-grouping 100+ messages on every render.
    @State private var cachedMessageGroups: [ScheduleMessageDayGroup] = []

    private var provider: Provider { viewModel.activeAgentProvider }
    private var automaticProvider: Provider { viewModel.automaticAgentProvider }
    private var model: String { viewModel.economicalModel(for: provider) }
    private var canUseAgent: Bool {
        viewModel.hasRemindersAccess || viewModel.hasCalendarAccess || !viewModel.courseSchedule.isEmpty || chaoxingService.isLoggedIn
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                TodayWidgetView()
                    .environmentObject(viewModel)
                
                ScheduleSidebarView(showCSVImporter: $showCSVImporter)
                    .environmentObject(viewModel)
            }
            .frame(width: 340)
            .padding(.leading, 14)
            .padding(.vertical, 12)

            ZStack(alignment: .bottomTrailing) {
                scheduleWorkspace
                VStack(alignment: .trailing, spacing: 12) {
                    floatingAgentChat
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar { scheduleToolbar }
        .background(.windowBackground)
        .safeAreaPadding(.top, 8)
        .onAppear {
            viewModel.refreshRemindersAccess()
            viewModel.refreshCalendarAccess()
            Task {
                // Only show the system dialog when the OS hasn't asked before
                // (notDetermined). requestRemindersAccess / requestCalendarAccess
                // already guard this internally, so these calls are safe.
                await viewModel.requestRemindersAccess()
                await viewModel.requestCalendarAccess()
                await viewModel.refreshScheduleSidebar()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshScheduleSidebar() }
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importCourseSchedule(from: url) }
            case .failure(let error):
                viewModel.scheduleErrorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editingCapture) { item in
            EditQuickCaptureSheet(item: item) { updated, shouldSend in
                viewModel.updateQuickCapture(updated)
                if shouldSend {
                    viewModel.sendQuickCaptureToScheduleAgent(updated)
                }
            }
        }
    }

    private var scheduleWorkspace: some View {
        ScheduleWeekTableView()
            .environmentObject(viewModel)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var floatingQuickCaptureDock: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isCaptureDockExpanded {
                QuickCaptureDockPanel(
                    onEdit: { editingCapture = $0 },
                    onClose: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            isCaptureDockExpanded = false
                        }
                    }
                )
                .environmentObject(viewModel)
                .transition(.scale(0.94, anchor: .bottomTrailing).combined(with: .opacity).combined(with: .blurReplace))
            }

            Button {
                withAnimation(.uiSpring) {
                    isCaptureDockExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tray.full.fill")
                        .font(.callout.weight(.semibold))
                    Text("中转站")
                        .font(.callout.weight(.semibold))
                    Text("\(viewModel.quickCaptures.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.22), in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.indigo.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.32), lineWidth: 1))
                .shadow(color: Color.indigo.opacity(0.24), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .pressScaleEffect()
            .help("打开中转站")
        }
    }

    @ViewBuilder
    private var floatingAgentChat: some View {
        if isAgentChatExpanded {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label("Agent", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    scheduleAgentProviderMenu
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                    Button {
                        withAnimation(.uiSpring) {
                            isAgentChatExpanded = false
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("收起")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.45)

                messageList
                    .frame(minHeight: 220, idealHeight: 360, maxHeight: 430)

                if let err = viewModel.scheduleErrorMessage { errorBanner(err) }
                if let confirmation = viewModel.pendingScheduleConfirmation {
                    ScheduleConfirmationPanel(confirmation: confirmation)
                }

                Divider().opacity(0.45)
                inputBar
            }
            .frame(width: 470)
            .adaptiveGlass(cornerRadius: 24)
            .floatingShadow()
            .transition(.scale(0.94, anchor: .bottomTrailing).combined(with: .opacity).combined(with: .blurReplace))
        } else {
            Button {
                withAnimation(.uiSpring) {
                    isAgentChatExpanded = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.isScheduleAgentRunning ? "sparkles" : "message.fill")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: viewModel.isScheduleAgentRunning)
                    Text(viewModel.isScheduleAgentRunning ? "处理中" : "日程 Agent")
                        .font(.callout.weight(.semibold))
                    if !viewModel.scheduleMessages.isEmpty {
                        Text("\(viewModel.scheduleMessages.count)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.2), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.accentColor.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.32), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.24), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .pressScaleEffect()
            .transition(.scale(0.9, anchor: .bottomTrailing).combined(with: .opacity).combined(with: .blurReplace))
        }
    }

    @ViewBuilder
    private func permissionBadge(
        granted: Bool,
        grantedLabel: String,
        pendingLabel: String,
        pendingIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        if granted {
            Label(grantedLabel, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: action) {
                Label(pendingLabel, systemImage: pendingIcon)
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help("点击授权（仅首次需要）")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var selectedScheduleProvider: Provider? {
        viewModel.allProviders.first(where: { $0.id == viewModel.scheduleAgentProviderSelectionID })
    }

    private var scheduleAgentProviderMenu: some View {
        Menu {
            Button { viewModel.updateScheduleAgentProviderSelection(ChatViewModel.automaticScheduleAgentProviderID) } label: {
                Label("自动：\(automaticProvider.name)", systemImage: "arrow.triangle.2.circlepath")
            }
            ForEach(viewModel.allProviders) { provider in
                Button { viewModel.updateScheduleAgentProviderSelection(provider.id) } label: {
                    Label(provider.name, systemImage: provider.iconName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.scheduleAgentProviderSelectionID == ChatViewModel.automaticScheduleAgentProviderID {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("自动：\(automaticProvider.name)").lineLimit(1)
                } else if let p = selectedScheduleProvider {
                    Image(systemName: p.iconName)
                    Text(p.name).lineLimit(1)
                } else {
                    Image(systemName: "questionmark")
                    Text("未知").lineLimit(1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择日程 Agent 使用的 API 提供商")
        .disabled(viewModel.isScheduleAgentRunning)
    }

    @ToolbarContentBuilder
    private var scheduleToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            scheduleAgentProviderMenu
            
            Text(model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !viewModel.hasRemindersAccess {
                Button(action: {
                    Task {
                        if await viewModel.requestRemindersAccess() { await viewModel.refreshScheduleSidebar() }
                    }
                }) {
                    Label("提醒授权", systemImage: "lock.open")
                }
                .help("授权访问提醒事项")
                .foregroundStyle(.orange)
            }
            if !viewModel.hasCalendarAccess {
                Button(action: {
                    Task {
                        if await viewModel.requestCalendarAccess() { await viewModel.refreshScheduleSidebar() }
                    }
                }) {
                    Label("日历授权", systemImage: "calendar.badge.plus")
                }
                .help("授权访问日历")
                .foregroundStyle(.orange)
            }

            Button {
                Task { await viewModel.refreshScheduleSidebar() }
            } label: {
                if viewModel.isScheduleSidebarLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .help("刷新")

            Button {
                showCSVImporter = true
            } label: {
                Label("导入课程表", systemImage: "tablecells")
            }
            .help("导入课程表 CSV")

            Button {
                viewModel.clearScheduleAgentMessages()
            } label: {
                Label("清空记录", systemImage: "trash")
            }
            .help("清空日程 Agent 记录")
            .disabled(viewModel.scheduleMessages.isEmpty)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if viewModel.scheduleMessages.isEmpty {
                        emptyState
                            .id("empty")
                    } else {
                        ForEach(cachedMessageGroups) { group in
                            ScheduleDayGroupView(
                                group: group,
                                isExpanded: Binding(
                                    get: { expandedScheduleDays.contains(group.id) },
                                    set: { isExpanded in
                                        if isExpanded { expandedScheduleDays.insert(group.id) }
                                        else { expandedScheduleDays.remove(group.id) }
                                    }
                                )
                            )
                            .id(group.id)
                        }
                    }
                    if viewModel.isScheduleAgentRunning { TypingIndicator() }
                    Color.clear.frame(height: 1).id("schedule-bottom")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.scheduleMessages.count) {
                rebuildMessageGroups()
                applyDefaultScheduleDayExpansion()
                scroll(proxy)
            }
            // Rebuild on content change (streaming) but keep the scroll anchor.
            .onChange(of: viewModel.scheduleMessages.last?.content) {
                rebuildMessageGroups()
                scroll(proxy)
            }
            .onAppear {
                rebuildMessageGroups()
                applyDefaultScheduleDayExpansion()
                scroll(proxy)
            }
        }
    }

    // Computed on demand; call rebuildMessageGroups() to update cachedMessageGroups.
    private func makeMessageGroups() -> [ScheduleMessageDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.scheduleMessages) { message in
            calendar.startOfDay(for: message.timestamp)
        }
        return grouped.keys.sorted().map { day in
            let messages = (grouped[day] ?? []).sorted { $0.timestamp < $1.timestamp }
            return ScheduleMessageDayGroup(day: day, messages: messages)
        }
    }

    private func rebuildMessageGroups() {
        cachedMessageGroups = makeMessageGroups()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(canUseAgent ? "今天要安排什么？" : "需要授权提醒事项/日历、导入课程表或登录学习通")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    // MARK: - Slash suggestions

    private var slashSuggestions: [SlashCommand] {
        guard inputText.hasPrefix("/") else { return [] }
        let query = String(inputText.dropFirst())
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allSlashCommands }
        return allSlashCommands.filter {
            $0.trigger.hasPrefix(query) ||
            $0.label.localizedCaseInsensitiveContains(query)
        }
    }

    private func executeSlashCommand(_ command: SlashCommand) {
        inputText = ""
        selectedSuggestionIdx = 0
        switch command.kind {
        case .resetContext:
            withAnimation(.quickSpring) { viewModel.resetScheduleAgentContext() }
        case .clearMessages:
            withAnimation(.quickSpring) { viewModel.clearScheduleAgentMessages() }
        case .agentPrompt(let prompt):
            viewModel.startSendingScheduleAgentMessage(prompt)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Slash-command suggestion menu
            if !slashSuggestions.isEmpty {
                SlashCommandMenuView(
                    commands: slashSuggestions,
                    selectedIndex: min(selectedSuggestionIdx, slashSuggestions.count - 1),
                    onSelect: { executeSlashCommand($0) }
                )
                .padding(.horizontal, 12)
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                    .combined(with: .opacity)
                )
            }

            // Input row
            HStack(alignment: .bottom, spacing: 10) {
                MessageInputField(
                    text: $inputText,
                    measuredHeight: $inputHeight,
                    placeholder: canUseAgent
                        ? "发消息或输入 / 使用命令…"
                        : "请先授权提醒事项/日历、导入课程表或登录学习通",
                    isDisabled: !canUseAgent,
                    maxHeight: 120,
                    onSubmit: submitMessage,
                    onMoveUp: {
                        guard !slashSuggestions.isEmpty else { return }
                        withAnimation(.quickSpring) {
                            selectedSuggestionIdx =
                                (selectedSuggestionIdx - 1 + slashSuggestions.count)
                                % slashSuggestions.count
                        }
                    },
                    onMoveDown: {
                        guard !slashSuggestions.isEmpty else { return }
                        withAnimation(.quickSpring) {
                            selectedSuggestionIdx =
                                (selectedSuggestionIdx + 1) % slashSuggestions.count
                        }
                    },
                    onTab: {
                        guard !slashSuggestions.isEmpty else { return }
                        let idx = min(selectedSuggestionIdx, slashSuggestions.count - 1)
                        // Tab fills in the full command text; Return will then execute it
                        inputText = "/" + slashSuggestions[idx].trigger
                    }
                )
                .frame(height: inputHeight)
                .padding(10)
                .background(Color(.textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    if viewModel.isScheduleAgentRunning { viewModel.cancelScheduleAgentResponse() }
                    else { submitMessage() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(agentSendFillColor)
                            .frame(width: 36, height: 36)
                            .shadow(color: agentSendFillColor.opacity(0.28), radius: 4, x: 0, y: 2)
                        Group {
                            if viewModel.isScheduleAgentRunning {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.white)
                                    .frame(width: 11, height: 11)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .animation(.quickSpring, value: viewModel.isScheduleAgentRunning)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .disabled(!viewModel.isScheduleAgentRunning &&
                          (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canUseAgent))
                .animation(.quickSpring, value: agentSendFillColor)
            }
        }
        .padding(12)
        .animation(.quickSpring, value: slashSuggestions.map(\.id))
        // Reset highlight when suggestion list changes
        .onChange(of: slashSuggestions.map(\.id)) { _, _ in
            selectedSuggestionIdx = 0
        }
    }

    private var agentSendFillColor: Color {
        if viewModel.isScheduleAgentRunning { return .red }
        if !canUseAgent || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Color(.disabledControlTextColor).opacity(0.3)
        }
        return .accentColor
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
            Text(msg).font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.quickSpring) { viewModel.scheduleErrorMessage = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.08))
        .transition(.opacity.combined(with: .push(from: .top)))
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.scrollEase) { proxy.scrollTo("schedule-bottom", anchor: .bottom) }
    }

    private func applyDefaultScheduleDayExpansion() {
        guard !didApplyScheduleDayDefaults else { return }
        expandedScheduleDays = [ScheduleMessageDayGroup.id(for: Date())]
        didApplyScheduleDayDefaults = true
    }

    private func submitMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Slash command: exact match on full trigger (e.g. "/today")
        if text.hasPrefix("/") {
            let trigger = String(text.dropFirst()).lowercased()
            if let cmd = allSlashCommands.first(where: { $0.trigger == trigger }) {
                executeSlashCommand(cmd)
                return
            }
            // Partial: execute the currently highlighted suggestion on Return
            if !slashSuggestions.isEmpty {
                let idx = min(selectedSuggestionIdx, slashSuggestions.count - 1)
                executeSlashCommand(slashSuggestions[idx])
                return
            }
        }

        inputText = ""
        selectedSuggestionIdx = 0
        viewModel.startSendingScheduleAgentMessage(text)
    }
}

struct ScheduleMessageDayGroup: Identifiable {
    let day: Date
    let messages: [Message]

    var id: String {
        Self.id(for: day)
    }

    static func id(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

struct ScheduleDayGroupView: View {
    let group: ScheduleMessageDayGroup
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 8) {
                ForEach(group.messages) { message in
                    ScheduleMessageView(message: message)
                        .id(message.id)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Label(group.title, systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                Text("\(group.messages.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - Today Widget

struct TodayWidgetView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("今日事务", systemImage: "sun.max.fill")
                    .font(.headline)
                Spacer()
                if viewModel.isTodayWidgetSummaryRunning {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                } else if let generatedAt = viewModel.todayWidget.generatedAt {
                    Text(formatSidebarDate(generatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
                Button {
                    Task { await viewModel.refreshScheduleSidebar() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("刷新今日事务")
                .disabled(viewModel.isTodayWidgetSummaryRunning)
            }
            .animation(.quickSpring, value: viewModel.isTodayWidgetSummaryRunning)

            Text(viewModel.todayWidget.summary)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.quickSpring, value: viewModel.todayWidget.summary)

            if viewModel.todayWidget.hasVisibleItems {
                VStack(alignment: .leading, spacing: 6) {
                    let primary = viewModel.todayWidget.attentionItems.filter { $0.horizon == "primary" }
                    let upcoming = viewModel.todayWidget.attentionItems.filter { $0.horizon == "upcoming" }
                    if !primary.isEmpty {
                        TodayWidgetSectionLabel("现在/今天最该注意")
                        ForEach(primary.prefix(3)) { item in
                            TodayWidgetMiniRow(
                                icon: attentionIcon(item),
                                tint: attentionTint(item),
                                title: item.title,
                                detail: item.detail,
                                onArchive: item.kind == "memory" ? { viewModel.archiveMemoryInsight(id: item.id) } : nil
                            )
                        }
                    }
                    if !upcoming.isEmpty {
                        TodayWidgetSectionLabel("未来 48 小时")
                        ForEach(upcoming.prefix(4)) { item in
                            TodayWidgetMiniRow(
                                icon: attentionIcon(item),
                                tint: attentionTint(item),
                                title: item.title,
                                detail: item.detail,
                                onArchive: item.kind == "memory" ? { viewModel.archiveMemoryInsight(id: item.id) } : nil
                            )
                        }
                    }
                    if primary.isEmpty && upcoming.isEmpty {
                        ForEach(viewModel.todayWidget.memoryHighlights.prefix(3)) { item in
                            TodayWidgetMiniRow(
                                icon: "exclamationmark.bubble.fill",
                                tint: item.importance == "high" ? .orange : .blue,
                                title: item.title,
                                detail: item.actionHint ?? item.summary,
                                onArchive: { viewModel.archiveMemoryInsight(id: "mem-\(item.id)") }
                            )
                        }
                    }
                }
                .padding(.top, 2)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(cornerRadius: 18)
    }

    private func attentionIcon(_ item: TodayAttentionItem) -> String {
        switch item.kind {
        case "assignment": return "books.vertical.fill"
        case "reminder": return "checkmark.circle.fill"
        case "event": return "calendar.circle.fill"
        case "course": return "graduationcap.circle.fill"
        case "memory": return "exclamationmark.bubble.fill"
        default: return "circle.fill"
        }
    }

    private func attentionTint(_ item: TodayAttentionItem) -> Color {
        switch item.kind {
        case "assignment": return .purple
        case "reminder": return .green
        case "event": return .blue
        case "course": return .teal
        case "memory": return item.score >= 50 ? .orange : .blue
        default: return .secondary
        }
    }
}

struct TodayWidgetSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

struct TodayWidgetMiniRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var onArchive: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer(minLength: 0)
            
            if let onArchive = onArchive {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Schedule Sidebar

struct ScheduleSidebarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var chaoxingService = ChaoxingService.shared
    @Binding var showCSVImporter: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.isScheduleSidebarLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }

                    sidebarSection(
                        title: "最近日程",
                        icon: "calendar.badge.clock",
                        emptyText: viewModel.hasCalendarAccess ? "未来两周没有日程" : "需要日历授权"
                    ) {
                        ForEach(viewModel.scheduleSidebar.events) { event in
                            ScheduleSidebarEventRow(event: event, accent: .blue)
                        }
                    }

                    sidebarSection(
                        title: "学习通 DDL",
                        icon: "books.vertical.fill",
                        emptyText: chaoxingService.isLoggedIn ? "暂无未完成学习通 DDL" : "设置中扫码登录学习通"
                    ) {
                        ForEach(viewModel.scheduleSidebar.chaoxingAssignments) { assignment in
                            ScheduleSidebarChaoxingAssignmentRow(assignment: assignment)
                        }
                    }

                    sidebarSection(
                        title: "待办事项",
                        icon: "checklist",
                        emptyText: viewModel.hasRemindersAccess ? "没有待办事项" : "需要提醒事项授权"
                    ) {
                        ForEach(viewModel.scheduleSidebar.reminders) { reminder in
                            ScheduleSidebarReminderRow(reminder: reminder)
                        }
                    }
                }
                .padding(12)
            }
            .clipped()
        }
        .adaptiveGlass(cornerRadius: 22)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("日程概览", systemImage: "sidebar.left")
                .font(.headline)
            Spacer()

            Button {
                Task { await viewModel.refreshScheduleSidebar() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("刷新")

            Button {
                showCSVImporter = true
            } label: {
                Image(systemName: "tablecells")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("导入课程表 CSV")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.1))
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        title: String,
        icon: String,
        emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let count = sectionCount(title)
            if count == 0 {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                content()
            }
        }
    }

    private func sectionCount(_ title: String) -> Int {
        switch title {
        case "最近日程": return viewModel.scheduleSidebar.events.count
        case "学习通 DDL": return viewModel.scheduleSidebar.chaoxingAssignments.count
        default: return viewModel.scheduleSidebar.reminders.count
        }
    }
}

struct QuickCaptureDockPanel: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let onEdit: (QuickCaptureItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("捕获中转站", systemImage: "tray.full")
                    .font(.headline)
                Text("\(viewModel.quickCaptures.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Button {
                    viewModel.sendQuickCapturesToScheduleAgent()
                } label: {
                    Label("全部发送", systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("批量发送中转站内容给日程 Agent")
                .disabled(viewModel.quickCaptures.isEmpty || viewModel.isScheduleAgentRunning)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("收起")
            }

            if viewModel.quickCaptures.isEmpty {
                Text("按 ⌥Space 从聊天 App 保存通知")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.quickCaptures) { item in
                            QuickCaptureBubble(
                                item: item,
                                onEdit: { onEdit(item) },
                                onSend: { viewModel.sendQuickCaptureToScheduleAgent(item) },
                                onDelete: { viewModel.deleteQuickCapture(item) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
        .frame(maxHeight: 420)
        .adaptiveGlass(cornerRadius: 24)
        .background(
            Button("") { onClose() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .floatingShadow()
    }
}

struct QuickCaptureBubble: View {
    let item: QuickCaptureItem
    let onEdit: () -> Void
    let onSend: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.sourceApp)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(formatSidebarDate(item.capturedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                iconButton("square.and.pencil", help: "编辑", action: onEdit)
                iconButton("paperplane.fill", help: "发送", action: onSend)
                iconButton("trash", help: "删除", role: .destructive, action: onDelete)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.secondary.opacity(0.14))
        )
    }

    private func iconButton(_ systemImage: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .secondary)
        .contentShape(Circle())
        .help(help)
    }
}

struct EditQuickCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: QuickCaptureItem
    let onSave: (QuickCaptureItem, Bool) -> Void

    init(item: QuickCaptureItem, onSave: @escaping (QuickCaptureItem, Bool) -> Void) {
        _item = State(initialValue: item)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("编辑中转站内容", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                Text(item.sourceApp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            TextEditor(text: $item.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(.textBackgroundColor).opacity(0.45))

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(item, false)
                    dismiss()
                }
                Button {
                    onSave(item, true)
                    dismiss()
                } label: {
                    Label("保存并发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
    }
}

struct ScheduleSidebarEventRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let event: ScheduleCalendarEventItem
    let accent: Color
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)

                    Text(formatSidebarEventTime(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !event.calendarName.isEmpty {
                        Text(event.calendarName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    viewModel.toggleEventImportance(event)
                } label: {
                    Image(systemName: viewModel.isImportantEvent(event) ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isImportantEvent(event) ? .yellow : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help(viewModel.isImportantEvent(event) ? "取消重要" : "标记为重要")
            }

            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            let annotations = viewModel.courseMemoryAnnotations(for: event)
            if !annotations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(annotations) { annotation in
                        CourseMemoryAnnotationPill(annotation: annotation, compact: true)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Color.accentColor.opacity(0.06) : Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .scaleEffect(hovered ? 1.012 : 1.0, anchor: .leading)
        .animation(.quickSpring, value: hovered)
        .onHover { hovered = $0 }
    }
}

struct ScheduleSidebarReminderRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let reminder: ScheduleReminderItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(reminder.listName)
                    if let dueDate = reminder.dueDate {
                        Text("·")
                        Text(formatSidebarDate(dueDate))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button {
                    viewModel.toggleReminderImportance(reminder)
                } label: {
                    Image(systemName: viewModel.isImportantReminder(reminder) ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isImportantReminder(reminder) ? .yellow : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help(viewModel.isImportantReminder(reminder) ? "取消重要" : "标记为重要")

                Button {
                    viewModel.openReminderInReminders(id: reminder.id)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help("在提醒事项中打开")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScheduleSidebarChaoxingAssignmentRow: View {
    let assignment: ScheduleChaoxingAssignmentItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.pink)
                .frame(width: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(assignment.courseName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(formatSidebarDate(assignment.dueDate))
                        .foregroundStyle(.orange)
                    if !assignment.remainingTime.isEmpty {
                        Text("·")
                        Text(assignment.remainingTime)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help("学习通作业")
    }
}

struct ScheduleSidebarChaoxingMessageBubble: View {
    let item: ScheduleChaoxingMessageInsightItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.importance == "high" ? "exclamationmark.bubble.fill" : "bubble.left.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.importance == "high" ? .orange : .green)
                .frame(width: 14)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }

                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(4)

                if let action = item.actionHint, !action.isEmpty {
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(item.conversationName)
                        .lineLimit(1)
                    // Show sender name only when it adds info (i.e. differs from conversation name)
                    if let name = item.senderName, name != item.conversationName {
                        Text("·")
                        Text(name)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Text("·")
                    Text(formatSidebarDate(item.sentAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.10))
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.green.opacity(0.10))
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .offset(x: -4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.reason.isEmpty ? "学习通重要消息" : item.reason)
    }
}

// MARK: - Week Timetable

struct ScheduleWeekTableView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    private let weekdays: [(title: String, value: Int)] = [
        ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5), ("周五", 6), ("周六", 7), ("周日", 1)
    ]

    private var items: [WeekTableItem] {
        let courses = viewModel.courseSchedule
            .filter { eventOverlapsCurrentWeek($0) }
            .map { WeekTableItem(event: $0, kind: .course) }
        let events = viewModel.scheduleSidebar.weekEvents
            .filter { eventOverlapsCurrentWeek($0) }
            .map { WeekTableItem(event: $0, kind: .event) }
        return (courses + events).sorted { $0.event.startDate < $1.event.startDate }
    }

    private var currentWeek: DateInterval {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let start = calendar.date(from: comps) ?? Date()
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    private func eventOverlapsCurrentWeek(_ event: ScheduleCalendarEventItem) -> Bool {
        DateInterval(start: event.startDate, end: max(event.endDate, event.startDate.addingTimeInterval(60))).intersects(currentWeek)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("本周课表", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text("课程 + 日历事件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(spacing: 0) {
                headerRow
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(defaultCoursePeriods) { period in
                            periodRow(period)
                            if period.id != defaultCoursePeriods.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(Color(.controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.bottom, 10)
        .adaptiveGlass(cornerRadius: 18)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("节")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34)

            ForEach(weekdays, id: \.value) { day in
                Text(day.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 30)
    }

    private func periodRow(_ period: CoursePeriod) -> some View {
        HStack(spacing: 0) {
            Text(period.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34)

            ForEach(weekdays, id: \.value) { day in
                ScheduleWeekTableCell(items: tableItems(day: day.value, period: period.id))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 58)
    }

    private func tableItems(day: Int, period: Int) -> [WeekTableItem] {
        items.filter { item in
            let calendar = Calendar.current
            guard calendar.component(.weekday, from: item.event.startDate) == day else { return false }
            guard let range = periodRange(for: item.event) else { return false }
            return range.lowerBound == period
        }
    }
}

struct WeekTableItem: Identifiable {
    enum Kind {
        case course, event
    }

    var id: String { "\(kind)-\(event.id)" }
    let event: ScheduleCalendarEventItem
    let kind: Kind
}

struct ScheduleWeekTableCell: View {
    let items: [WeekTableItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.prefix(2)) { item in
                ScheduleWeekBlock(item: item)
            }

            if items.count > 2 {
                Text("+\(items.count - 2)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.secondary.opacity(0.12)), alignment: .leading)
    }
}

struct ScheduleWeekBlock: View {
    let item: WeekTableItem

    private var rangeText: String {
        if item.event.isAllDay { return "全天" }
        guard let range = periodRange(for: item.event) else { return "" }
        return range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.event.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 4) {
                if !rangeText.isEmpty {
                    Text(rangeText)
                }
                if let location = item.event.location, !location.isEmpty {
                    Text(location)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.86))
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(blockColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var blockColor: Color {
        switch item.kind {
        case .course:
            return .teal
        case .event:
            return .blue
        }
    }
}

// MARK: - Schedule Agent Messages

struct ScheduleMessageView: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .system:
            contextResetDivider
        case .user:
            MessageBubble(message: message)
        case .assistant:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if let payload = message.schedulePayload, !payload.isEmpty {
                        SchedulePayloadView(payload: payload)
                    }
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScheduleMarkdownText(message.content)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.controlBackgroundColor))
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 4,
                                bottomLeadingRadius: 16,
                                bottomTrailingRadius: 16,
                                topTrailingRadius: 16))
                    }
                }
                Spacer(minLength: 60)
            }
            .padding(.horizontal)
        }
    }

    // Visual divider shown when the user resets LLM context via /reset
    private var contextResetDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            Label(message.content, systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .lineLimit(1)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .transition(.opacity)
    }
}

struct ScheduleMarkdownText: View {
    let text: String
    @State private var attributed: AttributedString?

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if let attributed {
                Text(attributed).textSelection(.enabled)
            } else {
                Text(text).textSelection(.enabled)
            }
        }
        // Parse markdown off the render cycle so streaming updates don't
        // re-parse all visible messages on every chunk.
        .task(id: text) {
            attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
        }
    }
}

struct ScheduleConfirmationPanel: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let confirmation: SchedulePendingConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: confirmation.isDestructive ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .foregroundStyle(confirmation.isDestructive ? .red : .orange)
                Text(confirmation.title)
                    .font(.headline)
                Spacer()
            }

            Text(confirmation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let payload = confirmation.payload, !payload.isEmpty {
                SchedulePayloadView(payload: payload)
                    .frame(maxHeight: 220)
                    .clipped()
            }

            HStack {
                Spacer()
                Button("取消") {
                    viewModel.resolveScheduleConfirmation(confirmed: false)
                }
                .keyboardShortcut(.escape)

                Button(confirmation.confirmTitle) {
                    viewModel.resolveScheduleConfirmation(confirmed: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(confirmation.isDestructive ? .red : .accentColor)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.secondary.opacity(0.18)), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.secondary.opacity(0.18)), alignment: .bottom)
    }
}

struct SchedulePayloadView: View {
    let payload: SchedulePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !payload.actions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(payload.actions) { action in
                        ScheduleActionRow(action: action)
                    }
                }
            }

            if !payload.lists.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "清单", count: payload.lists.count, icon: "list.bullet.rectangle")
                    ForEach(payload.lists) { list in
                        ScheduleListRow(list: list)
                    }
                }
            }

            if !payload.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "日历", count: payload.calendars.count, icon: "calendar")
                    ForEach(payload.calendars) { calendar in
                        ScheduleCalendarRow(calendar: calendar)
                    }
                }
            }

            if !payload.courses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "课程表", count: payload.courses.count, icon: "graduationcap")
                    ForEach(payload.courses) { course in
                        ScheduleCalendarEventRow(event: course, accent: .teal, icon: "graduationcap.circle.fill", canToggleImportance: false)
                    }
                }
            }

            if !payload.chaoxingAssignments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "学习通 DDL", count: payload.chaoxingAssignments.count, icon: "books.vertical.fill")
                    ForEach(payload.chaoxingAssignments) { assignment in
                        ScheduleChaoxingAssignmentRow(assignment: assignment)
                    }
                }
            }

            if !payload.chaoxingMessages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "学习通消息", count: payload.chaoxingMessages.count, icon: "bubble.left.and.bubble.right.fill")
                    ForEach(payload.chaoxingMessages) { item in
                        ScheduleSidebarChaoxingMessageBubble(item: item)
                    }
                }
            }

            let activeReminders = payload.reminders.filter { !$0.isCompleted }
            if !activeReminders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "提醒事项", count: activeReminders.count, icon: "checklist")
                    ForEach(activeReminders) { reminder in
                        ScheduleReminderRow(reminder: reminder)
                    }
                }
            }

            if !payload.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScheduleSectionHeader(title: "日历事件", count: payload.events.count, icon: "calendar.badge.clock")
                    ForEach(payload.events) { event in
                        ScheduleCalendarEventRow(event: event)
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct ScheduleSectionHeader: View {
    let title: String
    let count: Int
    let icon: String

    var body: some View {
        Label {
            Text("\(title) \(count)")
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}

struct ScheduleReminderRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let reminder: ScheduleReminderItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(reminder.isCompleted ? .green : .secondary)
                .frame(width: 18, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(reminder.listName, systemImage: "tray")
                    if let dueDate = reminder.dueDate {
                        Label(formatScheduleDate(dueDate), systemImage: "calendar")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 10)

            Button {
                viewModel.toggleReminderImportance(reminder)
            } label: {
                Image(systemName: viewModel.isImportantReminder(reminder) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(viewModel.isImportantReminder(reminder) ? .yellow : .secondary)
            .help(viewModel.isImportantReminder(reminder) ? "取消重要" : "标记为重要")

            Button {
                viewModel.openReminderInReminders(id: reminder.id)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("在提醒事项中打开")
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScheduleChaoxingAssignmentRow: View {
    let assignment: ScheduleChaoxingAssignmentItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 20, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(assignment.courseName, systemImage: "books.vertical")
                    Label(formatScheduleDate(assignment.dueDate), systemImage: "clock")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if !assignment.status.isEmpty {
                        Label(assignment.status, systemImage: "circle.dashed")
                    }
                    if !assignment.remainingTime.isEmpty {
                        Label(assignment.remainingTime, systemImage: "hourglass")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScheduleListRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let list: ScheduleReminderListItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(list.title)
                .font(.callout.weight(.medium))
            Spacer()
            Button {
                viewModel.openReminderListInReminders(id: list.id)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("在提醒事项中打开")
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScheduleCalendarRow: View {
    let calendar: ScheduleCalendarItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(calendar.title)
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScheduleCalendarEventRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let event: ScheduleCalendarEventItem
    var accent: Color = .blue
    var icon: String? = nil
    var canToggleImportance = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon ?? (event.isAllDay ? "sun.max.circle.fill" : "calendar.circle.fill"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(event.calendarName, systemImage: "calendar")
                    Label(formatEventRange(event), systemImage: "clock")
                        .foregroundStyle(accent)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                let annotations = viewModel.courseMemoryAnnotations(for: event)
                if !annotations.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(annotations) { annotation in
                            CourseMemoryAnnotationPill(annotation: annotation, compact: false)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 10)

            if canToggleImportance {
                Button {
                    viewModel.toggleEventImportance(event)
                } label: {
                    Image(systemName: viewModel.isImportantEvent(event) ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(viewModel.isImportantEvent(event) ? .yellow : .secondary)
                .help(viewModel.isImportantEvent(event) ? "取消重要" : "标记为重要")
            }
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CourseMemoryAnnotationPill: View {
    let annotation: CourseMemoryAnnotation
    var compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: annotation.importance == "high" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(annotation.importance == "high" ? .orange : .blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(annotation.title)
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Text(annotation.actionHint ?? annotation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background((annotation.importance == "high" ? Color.orange : Color.blue).opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct ScheduleActionRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let action: ScheduleActionItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.callout.weight(.semibold))
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let id = action.reminderID {
                Button {
                    viewModel.openReminderInReminders(id: id)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("在提醒事项中打开")
            }
            if action.calendarEventID != nil {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                    .help("日历事件")
            }
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch action.kind {
        case "created": return "plus.circle.fill"
        case "updated": return "pencil.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "deleted": return "trash.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch action.kind {
        case "deleted": return .red
        case "completed": return .green
        case "updated": return .blue
        default: return .accentColor
        }
    }
}

private func formatScheduleDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatEventRange(_ event: ScheduleCalendarEventItem) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = event.isAllDay ? .none : .short
    return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
}

private func formatSidebarEventTime(_ event: ScheduleCalendarEventItem) -> String {
    let calendar = Calendar.current
    let day = DateFormatter()
    day.dateStyle = .medium
    day.timeStyle = .none

    if event.isAllDay {
        return day.string(from: event.startDate)
    }

    let time = DateFormatter()
    time.dateStyle = .none
    time.timeStyle = .short

    if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
        return "\(day.string(from: event.startDate)) \(time.string(from: event.startDate))-\(time.string(from: event.endDate))"
    }

    return "\(day.string(from: event.startDate)) \(time.string(from: event.startDate))"
}

func formatSidebarDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func periodRange(for event: ScheduleCalendarEventItem) -> ClosedRange<Int>? {
    if event.isAllDay { return 1...1 }

    let calendar = Calendar.current
    let startMinutes = minutesSinceMidnight(event.startDate)
    let endMinutes = minutesSinceMidnight(event.endDate)

    let overlapping = defaultCoursePeriods.filter { period in
        let periodStart = period.startHour * 60 + period.startMinute
        let periodEnd = period.endHour * 60 + period.endMinute
        return max(startMinutes, periodStart) < min(endMinutes, periodEnd)
    }

    if let first = overlapping.first, let last = overlapping.last {
        return first.id...last.id
    }

    let nearest = defaultCoursePeriods.min { lhs, rhs in
        let lhsStart = lhs.startHour * 60 + lhs.startMinute
        let rhsStart = rhs.startHour * 60 + rhs.startMinute
        return abs(lhsStart - startMinutes) < abs(rhsStart - startMinutes)
    }

    if let nearest,
       calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
        return nearest.id...nearest.id
    }

    return nil
}

private func minutesSinceMidnight(_ date: Date) -> Int {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
}
