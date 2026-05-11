import Foundation
import SwiftUI
import AppKit
import EventKit
import PDFKit
import Combine
import CryptoKit

@MainActor
final class ChatViewModel: ObservableObject {

    static let defaultChatPersonaPrompt = """
    你是一个温暖、聪明、直接的中文聊天助手。优先给出可执行建议；不确定时说明边界；回答自然、简洁。除非用户明确要求格式化文档、代码、表格或清单，否则不要使用 Markdown 标题、表格和长列表。
    """

    static let defaultScheduleAgentPrompt = """
    优先把日程、提醒事项、课程表、学习通作业和学习通重要消息交给 App 的结构化 UI 展示。最终回复只写一句中文摘要。创建课程或日程前确认日期、时间、时区和目标日历；修改、完成、删除必须等待 App 内确认。
    """

    // MARK: - State
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isStreaming = false
    @Published var chatStreamingConversationID: UUID?
    @Published var activeToolStatus: String = ""
    @Published var isChatThinking: Bool = false
    @Published var errorMessage: String?
    @Published var scheduleMessages: [Message] = []
    @Published var isScheduleAgentRunning = false
    @Published var scheduleErrorMessage: String?
    @Published var hasRemindersAccess = false
    @Published var hasCalendarAccess = false
    @Published var pendingScheduleConfirmation: SchedulePendingConfirmation?
    @Published var scheduleSidebar = ScheduleSidebarSnapshot()
    @Published var todayWidget = TodayWidgetSnapshot()
    @Published var isTodayWidgetSummaryRunning = false
    @Published var isScheduleSidebarLoading = false
    @Published var scheduleSidebarLastUpdated: Date?
    @Published var courseSchedule: [ScheduleCalendarEventItem] = []
    @Published var quickCaptures: [QuickCaptureItem] = []
    @Published var shoppingListItems: [ShoppingListItem] = []
    @Published var importantScheduleItemIDs: Set<String> = []
    @Published var chaoxingMessageInsights: [ScheduleChaoxingMessageInsightItem] = []
    @Published var isChaoxingMessageExtractionRunning = false
    @Published var chaoxingRuntimeSyncStatus = ChaoxingRuntimeSyncStatus()
    @Published var companionState = CompanionState()
    @Published var companionPreferences = CompanionPreferences()
    @Published var companionClipboardOffer: CompanionClipboardOffer?
    @Published var chatAgentMode: ChatAgentMode = .normal
    @Published var chatAgentVisualization: ChatAgentVisualization?
    @Published var pendingChatToolConfirmation: ChatToolConfirmation?
    @Published var floatingChatConversationIDs: Set<UUID> = []
    @Published var scheduleContextResetAt: Date? = nil

    let remindersService = RemindersService()
    let legacyCourseImportMarker = "[ChatBotCourse]"
    let chaoxingMemoryStore = ChaoxingMemoryStore()
    var processedChaoxingMessageIDs: Set<String> = []
    var chaoxingMessageExtractionTask: Task<Void, Never>?
    var chatTask: Task<Void, Never>?
    var chatTaskID: UUID?
    var scheduleTask: Task<Void, Never>?
    var scheduleTaskID: UUID?
    var todayWidgetSummaryTask: Task<Void, Never>?
    var chaoxingRuntimeSyncTask: Task<Void, Never>?
    var companionFeedbackTask: Task<Void, Never>?
    var companionClipboardDismissTask: Task<Void, Never>?
    var chaoxingProbeSignatures: [String: String] = [:]
    var scheduleRefreshSequence = 0

    let harness = ScheduleHarness()
    lazy var scheduleOrchestrator = ScheduleOrchestrator(harness: harness)

    var cachedAgentReminders: [EKReminder] = []
    var cachedAgentEvents: [EKEvent] = []

    // MARK: - Providers
    @Published var customProviders: [Provider] = []
    @Published var providerModelOverrides: [String: [String]] = [:]
    var allProviders: [Provider] { Provider.builtins + customProviders }
    @Published var scheduleAgentProviderID: String?

    // MARK: - API Keys & Settings
    @Published var openAIKey = ""
    @Published var anthropicKey = ""
    @Published var geminiKey = ""
    @Published var mimoKey = ""
    @Published var chatPersonaPrompt = ChatViewModel.defaultChatPersonaPrompt
    @Published var scheduleAgentPrompt = ChatViewModel.defaultScheduleAgentPrompt
    @Published var promptsLocked = true
    @Published var chatSkills: [ChatSkill] = []
    @Published var deepThinkingEnabled = false
    @Published var showReasoningSummary = false
    @Published var webAccessEnabled = true
    @Published var scheduleModeEnabled = false
    @Published var pdfToolEnabled = false
    @Published var appleNotesToolEnabled = false
    @Published var shoppingListToolEnabled = false
    @Published var multiAgentEnabled = false
    @Published var isRoleplayMode = false
    @Published var agentThinkingBudgetTokens: Int = 0
    @Published var quickCaptureOpenScheduleAfterSave = true
    @Published var quickCaptureIncludeSourceMetadata = true
    @Published var quickCaptureKeepAfterSend = false

    @Published var chaoxingMutedConversationNames: Set<String> = []

    var scheduleConfirmationContinuation: CheckedContinuation<Bool, Never>?
    var chatToolConfirmationContinuation: CheckedContinuation<Bool, Never>?

    static let dataSchemaVersionKey = "data_schema_version"
    static let currentDataSchemaVersion = 1
    static let maxSkillScriptBytes = 256_000
    let maxWebFetchBytes = 220_000
    var pendingScheduleSaveTask: Task<Void, Never>?

    // MARK: - Computed
    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }
    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedConversationID }
    }
    var activeProvider: Provider {
        if let selectedConversation {
            return provider(for: selectedConversation.providerID)
        }
        return allProviders.first(where: isProviderUsable) ?? .openAI
    }
    static let automaticScheduleAgentProviderID = "__automatic_schedule_agent_provider__"

    var automaticAgentProvider: Provider {
        if isProviderUsable(activeProvider) { return activeProvider }
        return allProviders.first(where: isProviderUsable) ?? activeProvider
    }
    var activeAgentProvider: Provider {
        if let scheduleAgentProvider {
            return scheduleAgentProvider
        }
        return automaticAgentProvider
    }
    var scheduleAgentProvider: Provider? {
        guard let scheduleAgentProviderID else { return nil }
        return allProviders.first { $0.id == scheduleAgentProviderID }
    }
    var scheduleAgentProviderSelectionID: String {
        scheduleAgentProviderID ?? Self.automaticScheduleAgentProviderID
    }
    var balanceCheckProviders: [Provider] {
        allProviders.filter { $0.supportsBalanceCheck && !apiKey(for: $0).isEmpty }
    }

    init() {
        bootstrap()
    }
}


// --- Merged from ChatViewModel+API.swift ---


extension ChatViewModel {
    // MARK: - API Helpers
    func checkBalance(for provider: Provider) async throws -> [ProviderBalance] {
        let key = apiKey(for: provider)
        guard !key.isEmpty else { throw APIError.httpError(401, "No API key configured") }
        return try await fetchBalance(baseURL: provider.baseURL, apiKey: key)
    }

    func checkAPIReachability(for provider: Provider) async -> APIReachabilityResult {
        await checkProviderReachability(provider: provider, apiKey: apiKey(for: provider))
    }
}


// --- Merged from ChatViewModel+Agents.swift ---


extension ChatViewModel {
    // MARK: - Agents Shared Logic (Schedule, Memory, Companion)

    // MARK: - Chaoxing Memory Management

    internal var chaoxingMemoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("chaoxing_memory.json")
    }

    func readChaoxingMemory() -> String {
        let maintained = chaoxingMemoryStore.maintain()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(maintained) else {
            return chaoxingMemoryStore.readMemoryString()
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    internal func runChaoxingMemoryMaintenance(now: Date = Date()) {
        let maintained = chaoxingMemoryStore.maintain(now: now)
        chaoxingMessageInsights = ChaoxingMemoryReducer.insights(from: maintained, now: now, limit: 40)
    }

    func archiveMemoryInsight(id: String) {
        let actualID = id.replacingOccurrences(of: "mem-", with: "")
        var memory = chaoxingMemoryStore.readMemory()
        memory.entries.removeAll { $0.id == actualID }
        try? chaoxingMemoryStore.writeMemory(memory)
        
        if let idx = chaoxingMessageInsights.firstIndex(where: { $0.id == id }) {
            chaoxingMessageInsights.remove(at: idx)
        }
        
        refreshTodayWidgetFromCachedSidebar()
    }
    
    func refreshChaoxingMemoryForAgent() async -> String {
        chaoxingMemoryStore.physicalSweep()
        guard ChaoxingService.shared.isLoggedIn else {
            return "学习通 memory 未刷新：尚未登录学习通。"
        }
        if isChaoxingMessageExtractionRunning {
            return "学习通 Memory Agent 正在刷新中，请稍后读取 memory。"
        }

        isChaoxingMessageExtractionRunning = true
        defer { isChaoxingMessageExtractionRunning = false }

        let now = Date()
        let provider = activeAgentProvider
        let key = apiKey(for: provider)
        let assignments = (try? await ChaoxingService.shared.fetchAllPendingAssignments()) ?? []
        let assignmentItems = visibleChaoxingAssignmentItems(assignments, now: now)
        guard let messages = try? await ChaoxingService.shared.fetchRecentMessages(maxConversations: 12, perConversation: 20) else {
            return "学习通 memory 未刷新：近期消息拉取失败。"
        }

        let result = await ChaoxingMemoryAgent(store: chaoxingMemoryStore).process(
            messages: messages,
            assignments: assignmentItems,
            courses: courseSchedule,
            mutedConversationNames: chaoxingMutedConversationNames,
            provider: provider,
            model: economicalModel(for: provider),
            apiKey: key,
            now: now
        )
        processedChaoxingMessageIDs.formUnion(result.syncState.processedSourceIDs)
        saveChaoxingMessageState()
        chaoxingMessageInsights = Array(result.insights.prefix(40))
        scheduleSidebar.chaoxingMessageInsights = []
        chaoxingRuntimeSyncStatus.lastFullFetchAt = now
        chaoxingRuntimeSyncStatus.lastSuccessfulFetchAt = now
        chaoxingRuntimeSyncStatus.activeImportanceWindowUntil = now.addingTimeInterval(10 * 60)
        saveChaoxingRuntimeState()
        refreshTodayWidgetFromCachedSidebar()

        if key.isEmpty {
            return "学习通 memory 已完成本地去重/清理，但未执行语义提取：当前 agent provider 没有可用 API key。"
        }
        return "学习通 memory 已刷新：扫描 \(messages.count) 条近期消息，候选 \(result.candidateCount) 条，保留/更新 \(result.keptCount) 条语义记忆。"
    }

    @discardableResult
    func writeChaoxingMemory(_ json: String) async -> Bool {
        chaoxingMemoryStore.writeMemoryString(json)
    }

    func toggleChaoxingConversationMute(_ name: String) {
        if chaoxingMutedConversationNames.contains(name) {
            chaoxingMutedConversationNames.remove(name)
        } else {
            chaoxingMutedConversationNames.insert(name)
        }
        saveChaoxingMessageState()
        Task { await refreshScheduleSidebar() }
    }

    func setChaoxingMuted(_ name: String, muted: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if muted {
            chaoxingMutedConversationNames.insert(trimmed)
        } else {
            chaoxingMutedConversationNames.remove(trimmed)
        }
        saveChaoxingMessageState()
        Task { await refreshScheduleSidebar() }
    }

    // MARK: - Companion Pet Management

    func snoozeCompanion(minutes: Int = 60) {
        companionPreferences.quietUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        saveCompanionState()
        refreshCompanionState(reason: "snooze")
    }

    func enableCompanionPet() {
        companionPreferences.isEnabled = true
        companionPreferences.quietUntil = nil
        saveCompanionState()
        refreshCompanionState(reason: "show")
    }

    func performCompanionSuggestedAction() {
        if companionState.suggestedAction == "open_today" {
            NotificationCenter.default.post(name: .openScheduleAgent, object: nil)
            isTodayWidgetSummaryRunning = false
        }
    }

    func openReminderInReminders(id: String) {
        remindersService.openReminder(id: id)
    }

    func openReminderListInReminders(id: String) {
        remindersService.openList(id: id)
    }

    func resolveScheduleConfirmation(confirmed: Bool) {
        pendingScheduleConfirmation = nil
        if let continuation = scheduleConfirmationContinuation {
            scheduleConfirmationContinuation = nil
            continuation.resume(returning: confirmed)
        }
    }

    func confirmScheduleMutation(
        kind: SkillMutationKind,
        entitySummary: String,
        changesSummary: String,
        payload: SchedulePayload? = nil,
        conversationID: UUID? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            scheduleConfirmationContinuation = continuation
            pendingScheduleConfirmation = SchedulePendingConfirmation(
                title: kind.title,
                detail: "\(entitySummary)\n\n\(changesSummary)",
                confirmTitle: kind.confirmButton,
                isDestructive: kind.isDestructive,
                payload: payload
            )
        }
    }

    func refreshCompanionState(reason: String = "manual") {
        let next = CompanionEngine.makeState(
            today: todayWidget,
            memory: chaoxingMessageInsights,
            syncStatus: chaoxingRuntimeSyncStatus
        )
        companionState = next
        saveCompanionState()
        if companionPreferences.useLLMFeedback {
            regenerateCompanionFeedback(for: next, reason: reason)
        }
    }

    func dismissCompanionClipboardOffer() {
        companionClipboardOffer = nil
        companionClipboardDismissTask?.cancel()
        companionClipboardDismissTask = nil
    }

    func acceptCompanionClipboardOffer(sendToAgent: Bool) {
        guard let offer = companionClipboardOffer else { return }
        let id = addQuickCapture(text: offer.text, sourceApp: offer.sourceApp, capturedAt: offer.capturedAt)
        companionClipboardOffer = nil
        guard sendToAgent,
              let id,
              let item = quickCaptures.first(where: { $0.id == id }) else { return }
        sendQuickCaptureToScheduleAgent(item)
    }

    func analyzeCompanionClipboardOffer() {
        acceptCompanionClipboardOffer(sendToAgent: false)
        NotificationCenter.default.post(name: .openScheduleAgent, object: nil)
    }

    func sendQuickCapturesToScheduleAgent() {
        let items = quickCaptures
        guard !items.isEmpty else { return }
        startSendingScheduleAgentMessage(
            quickCapturePrompt(for: items),
            displayText: quickCaptureDisplayText(for: items)
        )
        quickCaptures.removeAll()
        saveQuickCaptures()
    }

    internal func regenerateCompanionFeedback(for state: CompanionState, reason: String) {
        companionFeedbackTask?.cancel()
        companionFeedbackTask = Task { [weak self] in
            guard let self else { return }
            let provider = self.activeAgentProvider
            let key = self.apiKey(for: provider)
            guard !key.isEmpty else { return }
            guard state.urgency != "none" || !state.suggestions.isEmpty else { return }

            do {
                let response = try await agentComplete(
                    messages: [
                        AgentMsg(role: .system, content: "Return only one short Chinese sentence. No markdown."),
                        AgentMsg(role: .user, content: CompanionEngine.llmPrompt(for: state, today: self.todayWidget))
                    ],
                    tools: [],
                    provider: provider,
                    model: self.economicalModel(for: provider),
                    apiKey: key
                )
                let text = (response.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                guard !Task.isCancelled, self.companionState.sourceHash == state.sourceHash, !text.isEmpty else { return }
                self.companionState.bubble = ChaoxingTextNormalizer.preview(text, limit: 34)
                self.companionState.llmBacked = true
                self.companionState.generatedAt = Date()
                self.saveCompanionState()
            } catch {
                return
            }
        }
    }
}


// --- Merged from ChatViewModel+Core.swift ---


extension ChatViewModel {
    // MARK: - Conversation management
    
    func createConversation(providerID: String? = nil) {
        let resolvedProviderID = providerID ?? activeProvider.id
        let p = provider(for: resolvedProviderID)
        let conv = Conversation(
            providerID: resolvedProviderID,
            model: p.defaultModel,
            agentMode: chatAgentMode,
            systemPrompt: chatPersonaPrompt
        )
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
    }

    func deleteConversation(_ conv: Conversation) {
        conversations.removeAll { $0.id == conv.id }
        if selectedConversationID == conv.id {
            selectedConversationID = conversations.first?.id
        }
        saveConversations()
    }

    func clearMessages(for convID: UUID? = nil) {
        let targetID = convID ?? selectedConversationID
        guard let i = conversations.firstIndex(where: { $0.id == targetID }) else { return }
        conversations[i].messages.removeAll()
        conversations[i].title = "New Chat"
        conversations[i].contextSummary = nil
        conversations[i].contextSummaryMessageCount = nil
        conversations[i].contextSummaryUpdatedAt = nil
        saveConversations()
    }

    func updateProvider(_ providerID: String, for convID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let p = provider(for: providerID)
        conversations[i].providerID = providerID
        conversations[i].model = availableModels(for: p).first ?? p.defaultModel
        saveConversations()
    }

    func updateModel(_ model: String, for convID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[i].model = model
        saveConversations()
    }

    func updateAgentMode(_ mode: ChatAgentMode, for convID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[i].agentMode = mode
        if selectedConversationID == convID {
            chatAgentMode = mode
        }
        saveConversations()
    }

    func updateSystemPrompt(_ prompt: String, for convID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[i].systemPrompt = prompt
        saveConversations()
    }

    internal func updateChatReasoning(conversationID: UUID, messageID: UUID, content: String) {
        mutateConversationMessage(conversationID: conversationID, messageID: messageID) { message in
            message.reasoningContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content
        }
    }

    internal func updateChatListPayload(conversationID: UUID, messageID: UUID, payload: ChatListPayload) {
        mutateConversationMessage(conversationID: conversationID, messageID: messageID) { message in
            message.chatListPayload = payload
        }
    }

    internal func updateChatSchedulePayload(conversationID: UUID, messageID: UUID, payload: SchedulePayload) {
        mutateConversationMessage(conversationID: conversationID, messageID: messageID) { message in
            var merged = message.schedulePayload ?? SchedulePayload()
            merged.merge(payload)
            message.schedulePayload = merged.isEmpty ? nil : merged
        }
    }

    internal func setUsageForAssistantTurn(conversationID: UUID, assistantID: UUID, usage: UsageStats) {
        guard let position = conversationMessagePosition(conversationID: conversationID, messageID: assistantID) else { return }
        conversations[position.conversationIndex].messages[position.messageIndex].usage = usage

        let messages = conversations[position.conversationIndex].messages
        let previousUserIndex = messages[..<position.messageIndex].lastIndex { $0.role == .user }
        if let previousUserIndex {
            conversations[position.conversationIndex].messages[previousUserIndex].usage = usage
        }
    }

    func startSendingMessage(_ text: String, conversationID: UUID? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = conversationID ?? selectedConversationID
        guard !trimmed.isEmpty, targetID != nil, chatTask == nil, !isStreaming else { return }

        let taskID = UUID()
        chatTaskID = taskID
        chatTask = Task { await sendMessage(text, conversationID: targetID, taskID: taskID) }
    }

    func cancelChatResponse() {
        chatTask?.cancel()
        chatTask = nil
        chatTaskID = nil
        isStreaming = false
        chatStreamingConversationID = nil
        errorMessage = nil
        pendingChatToolConfirmation = nil
        if let continuation = chatToolConfirmationContinuation {
            chatToolConfirmationContinuation = nil
            continuation.resume(returning: false)
        }
    }

    func sendMessage(_ text: String, conversationID: UUID? = nil, taskID: UUID? = nil) async {
        defer { finishChatTask(taskID) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = conversationID ?? selectedConversationID
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == targetID }) else { return }

        let prov  = provider(for: conversations[idx].providerID)
        let key   = apiKey(for: prov)
        guard !key.isEmpty else {
            errorMessage = "请在设置 (⌘,) 中填写 \(prov.name) 的 API Key"; return
        }
        let validModels = availableModels(for: prov)
        if !validModels.contains(conversations[idx].model),
           let fallbackModel = validModels.first ?? prov.models.first {
            conversations[idx].model = fallbackModel
            saveConversations()
        }

        conversations[idx].messages.append(Message(role: .user, content: trimmed))
        conversations[idx].updatedAt = Date()
        let convID = conversations[idx].id

        if conversations[idx].messages.count == 1 {
            let words = trimmed.components(separatedBy: .whitespaces).prefix(7).joined(separator: " ")
            conversations[idx].title = words + (trimmed.count > words.count ? "…" : "")
        }

        let mode = conversations[idx].agentMode
        let willUseMultiAgent = !isRoleplayMode && mode == .multiAgent && multiAgentCandidateProviders(active: prov).count >= 2
        let willUseDedicatedSubAgent = !isRoleplayMode && mode == .subAgent
        let effectiveMode: ChatAgentMode = willUseDedicatedSubAgent ? .subAgent : (willUseMultiAgent ? .multiAgent : .normal)
        let useChatTools = !willUseMultiAgent && !isRoleplayMode
        let now = Date()
        let sysPrompt = combinedChatSystemPrompt(
            for: conversations[idx],
            modeOverride: effectiveMode
        )
        let allMessages = buildCompressedChatPromptMessages(
            for: conversations[idx],
            systemPrompt: sysPrompt,
            now: now,
            persistSummary: true
        )

        let model   = conversations[idx].model
        let baseURL = prov.baseURL

        isStreaming  = true
        chatStreamingConversationID = convID
        errorMessage = nil

        let placeholder = Message(role: .assistant, content: "")
        conversations[idx].messages.append(placeholder)
        let assistantID = placeholder.id
        if !isRoleplayMode {
            startChatAgentVisualization(
                conversationID: convID,
                mode: effectiveMode,
                activeProvider: prov,
                model: model
            )
        }

        do {
            try Task.checkCancellation()
            if willUseMultiAgent {
                try await completeMultiAgentChat(
                    messages: allMessages,
                    conversationID: convID,
                    assistantID: assistantID,
                    primaryProvider: prov,
                    primaryModel: model,
                    primaryAPIKey: key,
                    originalUserText: trimmed
                )
            } else if useChatTools {
                try await completeChatWithSkillTools(
                    messages: allMessages,
                    conversationID: convID,
                    assistantID: assistantID,
                    provider: prov,
                    model: model,
                    apiKey: key
                )
            } else {
                let service = makeService(apiType: prov.apiType)
                let stream  = try await service.stream(messages: allMessages, model: model, apiKey: key, baseURL: baseURL, thinkingEnabled: deepThinkingEnabled)

                var accumulated = ""
                var reasoning = ""
                var pendingContent = false
                var pendingReasoning = false
                var lastFlush = ContinuousClock.now

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk
                        pendingContent = true
                    case .reasoning(let chunk):
                        reasoning += chunk
                        pendingReasoning = true
                    case .usage(var stats):
                        stats.estimatedCostUSD = knownPricing[model]?.cost(for: stats)
                        setUsageForAssistantTurn(
                            conversationID: convID,
                            assistantID: assistantID,
                            usage: stats
                        )
                    }

                    let currentNow = ContinuousClock.now
                    if (pendingContent || pendingReasoning) && currentNow - lastFlush >= .milliseconds(50) {
                        if let position = conversationMessagePosition(conversationID: convID, messageID: assistantID) {
                            if pendingContent {
                                conversations[position.conversationIndex].messages[position.messageIndex].content = accumulated
                                pendingContent = false
                            }
                            if pendingReasoning {
                                conversations[position.conversationIndex].messages[position.messageIndex].reasoningContent = reasoning
                                pendingReasoning = false
                            }
                        }
                        lastFlush = currentNow
                    }
                }

                if pendingContent || pendingReasoning,
                   let position = conversationMessagePosition(conversationID: convID, messageID: assistantID) {
                    if pendingContent {
                        conversations[position.conversationIndex].messages[position.messageIndex].content = accumulated
                    }
                    if pendingReasoning {
                        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                        conversations[position.conversationIndex].messages[position.messageIndex].reasoningContent = trimmedReasoning.isEmpty ? nil : trimmedReasoning
                    }
                }

                if accumulated.isEmpty && reasoning.isEmpty {
                    mutateConversationMessage(conversationID: convID, messageID: assistantID) { message in
                        message.content = "(empty response)"
                    }
                } else if accumulated.isEmpty {
                    mutateConversationMessage(conversationID: convID, messageID: assistantID) { message in
                        message.content = "（没有收到最终回答）"
                    }
                }
            }
            if let i = conversations.firstIndex(where: { $0.id == convID }) {
                conversations[i].updatedAt = Date()
            }
            saveConversations()
        } catch {
            if isCancellationError(error) {
                markChatResponseStopped(conversationID: convID, assistantID: assistantID)
            } else {
                mutateConversationMessage(conversationID: convID, messageID: assistantID) { message in
                    message.content = "**Error:** \(error.localizedDescription)"
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishChatTask(_ taskID: UUID?) {
        guard taskID == nil || chatTaskID == taskID else { return }
        isStreaming = false
        chatStreamingConversationID = nil
        chatTask = nil
        chatTaskID = nil
    }
    
    internal func migrateUserDefaultsIfNeeded() {
        let standard = UserDefaults.standard
        let stored   = standard.integer(forKey: ChatViewModel.dataSchemaVersionKey)  // 0 if never set
        guard stored < ChatViewModel.currentDataSchemaVersion else { return }

        // ── Migration v1: import legacy ChatBot.plist ─────────────────────────
        if stored < 1 {
            let legacyURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/ChatBot.plist")
            if let dict = NSDictionary(contentsOf: legacyURL) as? [String: Any],
               dict["conversations"] != nil {
                for (key, value) in dict {
                    guard !key.hasPrefix("NS"),
                          !key.hasPrefix("Apple"),
                          !key.hasPrefix("com.apple") else { continue }
                    standard.set(value, forKey: key)
                }
            }
        }

        // ── Migration v2: Skill+Harness refactor ──────────────────────────────
        if stored < 2 { }

        standard.set(ChatViewModel.currentDataSchemaVersion, forKey: ChatViewModel.dataSchemaVersionKey)
        standard.synchronize()
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(openAIKey,    forKey: "key_openai")
        d.set(anthropicKey, forKey: "key_anthropic")
        d.set(geminiKey,    forKey: "key_gemini")
        d.set(mimoKey,      forKey: "key_mimo")
        d.set(chatPersonaPrompt, forKey: "prompt_chat_persona")
        d.set(scheduleAgentPrompt, forKey: "prompt_schedule_agent")
        d.set(promptsLocked, forKey: "prompts_locked")
        d.set(deepThinkingEnabled, forKey: "deep_thinking_enabled")
        d.set(showReasoningSummary, forKey: "show_reasoning_summary")
        d.set(webAccessEnabled, forKey: "web_access_enabled")
        d.set(scheduleModeEnabled, forKey: "schedule_mode_enabled")
        d.set(pdfToolEnabled, forKey: "pdf_tool_enabled")
        d.set(appleNotesToolEnabled, forKey: "apple_notes_tool_enabled")
        d.set(shoppingListToolEnabled, forKey: "shopping_list_tool_enabled")
        d.set(multiAgentEnabled, forKey: "multi_agent_enabled")
        d.set(isRoleplayMode, forKey: "is_roleplay_mode")
        d.set(chatAgentMode.rawValue, forKey: "chat_agent_mode")
        d.set(agentThinkingBudgetTokens, forKey: "agent_thinking_budget_tokens")
        if let scheduleAgentProviderID {
            d.set(scheduleAgentProviderID, forKey: "schedule_agent_provider_id")
        } else {
            d.removeObject(forKey: "schedule_agent_provider_id")
        }
        d.set(quickCaptureOpenScheduleAfterSave, forKey: "quick_capture_open_schedule_after_save")
        d.set(quickCaptureIncludeSourceMetadata, forKey: "quick_capture_include_source_metadata")
        d.set(quickCaptureKeepAfterSend, forKey: "quick_capture_keep_after_send")
        saveImportantScheduleItems()
        if let data = try? JSONEncoder().encode(customProviders) { d.set(data, forKey: "custom_providers") }
        if let data = try? JSONEncoder().encode(providerModelOverrides) { d.set(data, forKey: "provider_model_overrides") }
        if let data = try? JSONEncoder().encode(chatSkills) { d.set(data, forKey: "chat_skills") }
        if let data = try? JSONEncoder().encode(Array(chaoxingMutedConversationNames).sorted()) {
            d.set(data, forKey: "chaoxing_muted_conversation_names")
        }
    }

    internal func loadSettings() {
        let d = UserDefaults.standard
        openAIKey    = d.string(forKey: "key_openai")    ?? ""
        anthropicKey = d.string(forKey: "key_anthropic") ?? ""
        geminiKey    = d.string(forKey: "key_gemini")    ?? ""
        mimoKey      = d.string(forKey: "key_mimo")      ?? ""
        chatPersonaPrompt = d.object(forKey: "prompt_chat_persona") as? String ?? ChatViewModel.defaultChatPersonaPrompt
        scheduleAgentPrompt = d.object(forKey: "prompt_schedule_agent") as? String ?? ChatViewModel.defaultScheduleAgentPrompt
        promptsLocked = d.object(forKey: "prompts_locked") as? Bool ?? true
        deepThinkingEnabled = d.object(forKey: "deep_thinking_enabled") as? Bool ?? false
        showReasoningSummary = d.object(forKey: "show_reasoning_summary") as? Bool ?? false
        if !deepThinkingEnabled { showReasoningSummary = false }
        webAccessEnabled = d.object(forKey: "web_access_enabled") as? Bool ?? true
        scheduleModeEnabled = d.object(forKey: "schedule_mode_enabled") as? Bool ?? false
        pdfToolEnabled = d.object(forKey: "pdf_tool_enabled") as? Bool ?? false
        appleNotesToolEnabled = d.object(forKey: "apple_notes_tool_enabled") as? Bool ?? false
        shoppingListToolEnabled = d.object(forKey: "shopping_list_tool_enabled") as? Bool ?? false
        multiAgentEnabled = d.object(forKey: "multi_agent_enabled") as? Bool ?? false
        isRoleplayMode = d.object(forKey: "is_roleplay_mode") as? Bool ?? false
        chatAgentMode = ChatAgentMode(rawValue: d.string(forKey: "chat_agent_mode") ?? "") ?? (multiAgentEnabled ? .normal : .normal)
        agentThinkingBudgetTokens = d.object(forKey: "agent_thinking_budget_tokens") as? Int ?? 0
        scheduleAgentProviderID = d.string(forKey: "schedule_agent_provider_id")
        quickCaptureOpenScheduleAfterSave = d.object(forKey: "quick_capture_open_schedule_after_save") as? Bool ?? true
        quickCaptureIncludeSourceMetadata = d.object(forKey: "quick_capture_include_source_metadata") as? Bool ?? true
        quickCaptureKeepAfterSend = d.object(forKey: "quick_capture_keep_after_send") as? Bool ?? false
        if let data = d.data(forKey: "important_schedule_item_ids"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            importantScheduleItemIDs = Set(ids)
        }
        if let data = d.data(forKey: "custom_providers"),
           let providers = try? JSONDecoder().decode([Provider].self, from: data) {
            customProviders = providers
        }
        if let providerID = scheduleAgentProviderID,
           !allProviders.contains(where: { $0.id == providerID }) {
            scheduleAgentProviderID = nil
        }
        if let data = d.data(forKey: "provider_model_overrides"),
           let overrides = try? JSONDecoder().decode([String: [String]].self, from: data) {
            providerModelOverrides = overrides
        }
        if let data = d.data(forKey: "chat_skills"),
           let skills = try? JSONDecoder().decode([ChatSkill].self, from: data) {
            chatSkills = skills
        }
        if let data = d.data(forKey: "chaoxing_muted_conversation_names"),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            chaoxingMutedConversationNames = Set(names)
        }
    }

    func saveConversations() {
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: "conversations")
        }
        refreshTodayWidgetFromCachedSidebar()
    }

    internal func loadConversations() {
        guard let data = UserDefaults.standard.data(forKey: "conversations"),
              let convs = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return }
        conversations = convs
    }

    private static var scheduleMessagesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedule_messages.json")
    }

    func saveScheduleMessages() {
        pendingScheduleSaveTask?.cancel()
        let snapshot = scheduleMessages
        let url = ChatViewModel.scheduleMessagesURL
        pendingScheduleSaveTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    internal func loadScheduleMessages() {
        let url = ChatViewModel.scheduleMessagesURL
        if let data = try? Data(contentsOf: url),
           let messages = try? JSONDecoder().decode([Message].self, from: data) {
            scheduleMessages = messages
            return
        }
        if let data = UserDefaults.standard.data(forKey: "schedule_agent_messages"),
           let messages = try? JSONDecoder().decode([Message].self, from: data) {
            scheduleMessages = messages
            saveScheduleMessages()
            UserDefaults.standard.removeObject(forKey: "schedule_agent_messages")
        }
    }

    func saveQuickCaptures() {
        if let data = try? JSONEncoder().encode(quickCaptures) {
            UserDefaults.standard.set(data, forKey: "quick_captures")
        }
        refreshTodayWidgetFromCachedSidebar()
    }

    func saveShoppingListItems() {
        if let data = try? JSONEncoder().encode(shoppingListItems) {
            UserDefaults.standard.set(data, forKey: "shopping_list_items")
        }
    }

    func saveChaoxingRuntimeState() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(chaoxingRuntimeSyncStatus) {
            defaults.set(data, forKey: "chaoxing_runtime_sync_status")
        }
        if let data = try? JSONEncoder().encode(chaoxingProbeSignatures) {
            defaults.set(data, forKey: "chaoxing_probe_signatures")
        }
    }

    internal func loadChaoxingRuntimeState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "chaoxing_runtime_sync_status"),
           let status = try? JSONDecoder().decode(ChaoxingRuntimeSyncStatus.self, from: data) {
            chaoxingRuntimeSyncStatus = status
            chaoxingRuntimeSyncStatus.isRefreshing = false
            chaoxingRuntimeSyncStatus.isRunning = true
        }
        if let data = defaults.data(forKey: "chaoxing_probe_signatures"),
           let signatures = try? JSONDecoder().decode([String: String].self, from: data) {
            chaoxingProbeSignatures = signatures
        }
    }

    func saveCompanionState() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(companionState) {
            defaults.set(data, forKey: "companion_state")
        }
        if let data = try? JSONEncoder().encode(companionPreferences) {
            defaults.set(data, forKey: "companion_preferences")
        }
    }

    internal func loadCompanionState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "companion_state"),
           let state = try? JSONDecoder().decode(CompanionState.self, from: data) {
            companionState = state
        }
        if let data = defaults.data(forKey: "companion_preferences"),
           let preferences = try? JSONDecoder().decode(CompanionPreferences.self, from: data) {
            companionPreferences = preferences
        }
    }

    func saveImportantScheduleItems() {
        if let data = try? JSONEncoder().encode(Array(importantScheduleItemIDs).sorted()) {
            UserDefaults.standard.set(data, forKey: "important_schedule_item_ids")
        }
    }

    func saveChaoxingMessageState() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(chaoxingMessageInsights) {
            defaults.set(data, forKey: "chaoxing_message_insights")
        }
        let finalIDs: Set<String>
        if processedChaoxingMessageIDs.count > 2_000 {
            let cutoff = Date().addingTimeInterval(-45 * 24 * 3600)
            let recentIDs = Set(chaoxingMessageInsights
                .filter { $0.sentAt > cutoff }
                .map { $0.sourceMessageID })
            finalIDs = recentIDs
        } else {
            finalIDs = processedChaoxingMessageIDs
        }
        if let data = try? JSONEncoder().encode(Array(finalIDs).sorted()) {
            defaults.set(data, forKey: "chaoxing_processed_message_ids")
        }
    }

    internal func loadChaoxingMessageState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "chaoxing_message_insights"),
           let items = try? JSONDecoder().decode([ScheduleChaoxingMessageInsightItem].self, from: data) {
            chaoxingMessageInsights = items.sorted { $0.sentAt > $1.sentAt }
        }
        if let data = defaults.data(forKey: "chaoxing_processed_message_ids"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            processedChaoxingMessageIDs = Set(ids)
        }
    }

    func saveTodayWidgetSnapshot() {
        if let data = try? JSONEncoder().encode(todayWidget) {
            UserDefaults.standard.set(data, forKey: "today_widget_snapshot")
        }
    }

    internal func loadTodayWidgetSnapshot() {
        if let data = UserDefaults.standard.data(forKey: "today_widget_snapshot"),
           let snapshot = try? JSONDecoder().decode(TodayWidgetSnapshot.self, from: data) {
            todayWidget = snapshot
        }
    }

    internal func loadQuickCaptures() {
        guard let data = UserDefaults.standard.data(forKey: "quick_captures"),
              let items = try? JSONDecoder().decode([QuickCaptureItem].self, from: data)
        else { return }
        quickCaptures = items.sorted { $0.updatedAt > $1.updatedAt }
    }

    internal func loadShoppingListItems() {
        guard let data = UserDefaults.standard.data(forKey: "shopping_list_items"),
              let items = try? JSONDecoder().decode([ShoppingListItem].self, from: data)
        else { return }
        shoppingListItems = items.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveCourseSchedule() {
        if let data = try? JSONEncoder().encode(courseSchedule) {
            UserDefaults.standard.set(data, forKey: "local_course_schedule")
        }
    }

    internal func loadCourseSchedule() {
        guard let data = UserDefaults.standard.data(forKey: "local_course_schedule"),
              let courses = try? JSONDecoder().decode([ScheduleCalendarEventItem].self, from: data)
        else { return }
        courseSchedule = courses
    }
}


// --- Merged from ChatViewModel+Course.swift ---


extension ChatViewModel {
    // MARK: - Course CSV import and parsing

    private struct CourseEventDraft {
        var title: String
        var startDate: Date
        var endDate: Date
        var notes: String?
        var location: String?
        var calendarName: String?
        var isAllDay: Bool
        var weeklyRecurrenceEndDate: Date?

        var preview: ScheduleCalendarEventItem {
            ScheduleCalendarEventItem(
                id: UUID().uuidString,
                title: title,
                calendarName: "本地课程表",
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: isAllDay
            )
        }

        func localEvent(startDate: Date, endDate: Date) -> ScheduleCalendarEventItem {
            ScheduleCalendarEventItem(
                id: "local-course-\(UUID().uuidString)",
                title: title,
                calendarName: "本地课程表",
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                isAllDay: isAllDay
            )
        }
    }

    func importCourseSchedule(from url: URL) async {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            let text: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: url)
            }
            let drafts = try parseCourseCSV(text)
            guard !drafts.isEmpty else {
                scheduleErrorMessage = "CSV 没有可导入的课程"
                return
            }

            let localCourses = localCourseEvents(from: drafts)
            let previewPayload = SchedulePayload(courses: Array(localCourses.prefix(12)))
            let recurrenceCount = drafts.filter { $0.weeklyRecurrenceEndDate != nil }.count
            let entitySummary = "文件：\(url.lastPathComponent)\n课程：\(drafts.count) 门\n本地课程时间块：\(localCourses.count) 条"
            let changes = recurrenceCount > 0
                ? "替换 App 内本地课程表，其中 \(recurrenceCount) 门课按周展开；不会写入 Calendar 或 Reminders"
                : "替换 App 内本地课程表；不会写入 Calendar 或 Reminders"

            guard await confirmScheduleMutation(
                kind: .importCourses,
                entitySummary: entitySummary,
                changesSummary: changes,
                payload: previewPayload
            ) else {
                scheduleMessages.append(Message(role: .assistant, content: "已取消导入课程表。"))
                saveScheduleMessages()
                return
            }

            courseSchedule = localCourses
            saveCourseSchedule()

            let payload = SchedulePayload(
                courses: Array(localCourses.prefix(20)),
                actions: [ScheduleActionItem(kind: "created", title: "已导入本地课程表", detail: "\(localCourses.count) 条本地课程时间块")]
            )
            scheduleMessages.append(Message(role: .assistant, content: "已导入本地课程表，不会写入系统日历。", schedulePayload: payload))
            saveScheduleMessages()
            await refreshScheduleSidebar()
        } catch {
            scheduleErrorMessage = error.localizedDescription
        }
    }

    private func localCourseEvents(from drafts: [CourseEventDraft]) -> [ScheduleCalendarEventItem] {
        let calendar = Calendar.current
        return drafts.flatMap { draft -> [ScheduleCalendarEventItem] in
            let duration = max(draft.endDate.timeIntervalSince(draft.startDate), 30 * 60)
            guard let recurrenceEnd = draft.weeklyRecurrenceEndDate else {
                return [draft.localEvent(startDate: draft.startDate, endDate: draft.endDate)]
            }

            let recurrenceLimit = endOfDay(recurrenceEnd)
            var events: [ScheduleCalendarEventItem] = []
            var start = draft.startDate
            var generated = 0

            while start <= recurrenceLimit && generated < 260 {
                events.append(draft.localEvent(startDate: start, endDate: start.addingTimeInterval(duration)))
                guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
                start = next
                generated += 1
            }

            return events
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    private func parseCourseCSV(_ text: String) throws -> [CourseEventDraft] {
        let rows = parseCSVRows(text)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let headerRow = rows.first else { return [] }
        let headers = headerRow.map(normalizeCSVHeader)

        return try rows.dropFirst().enumerated().compactMap { index, columns in
            var row: [String: String] = [:]
            for (columnIndex, header) in headers.enumerated() where !header.isEmpty {
                if columnIndex < columns.count {
                    row[header] = columns[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if row.values.allSatisfy(\.isEmpty) { return nil }
            do {
                return try courseDraft(from: row)
            } catch {
                throw APIError.httpError(400, "CSV 第 \(index + 2) 行无法解析：\(error.localizedDescription)")
            }
        }
    }

    private func courseDraft(from row: [String: String]) throws -> CourseEventDraft {
        guard let title = csvValue(row, ["title", "course", "name", "subject", "课程", "课程名称", "名称"]), !title.isEmpty else {
            throw APIError.httpError(400, "缺少课程名称")
        }

        let isAllDay = csvBool(row, ["all_day", "allday", "全天"]) ?? false
        let startDate = try courseStartDate(from: row)
        let endDate = try courseEndDate(from: row, startDate: startDate)

        return CourseEventDraft(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: csvValue(row, ["notes", "note", "备注", "说明"]),
            location: csvValue(row, ["location", "place", "room", "地点", "教室"]),
            calendarName: csvValue(row, ["calendar", "calendar_name", "日历"]),
            isAllDay: isAllDay,
            weeklyRecurrenceEndDate: try courseRecurrenceEndDate(from: row)
        )
    }

    private func courseStartDate(from row: [String: String]) throws -> Date {
        if let date = csvValue(row, ["date", "日期"]),
           let time = csvValue(row, ["start_time", "starttime", "开始时间", "上课时间"]) {
            return try parseCourseDate(date, time: time)
        }

        if let start = csvValue(row, ["start", "start_date", "startdatetime", "开始", "开始日期时间"]) {
            if let parsed = try parseAgentDate(start) { return parsed }
        }

        if let weekday = csvWeekday(row, ["weekday", "week_day", "周几", "星期"]),
           let time = csvValue(row, ["start_time", "starttime", "开始时间", "上课时间"]) {
            let termStart = try parseCSVDateOnly(csvValue(row, ["term_start", "semester_start", "学期开始", "起始日期"])) ?? Date()
            return try parseCourseDate(dateForNext(weekday: weekday, onOrAfter: termStart), time: time)
        }

        if let weekday = csvWeekday(row, ["weekday", "week_day", "周几", "星期"]),
           let range = csvPeriodRange(row),
           let period = defaultCoursePeriods.first(where: { $0.id == range.lowerBound }) {
            let termStart = try parseCSVDateOnly(csvValue(row, ["term_start", "semester_start", "学期开始", "起始日期"])) ?? Date()
            return dateForCoursePeriod(period, on: dateForNext(weekday: weekday, onOrAfter: termStart), useEndTime: false)
        }

        throw APIError.httpError(400, "缺少开始时间")
    }

    private func courseEndDate(from row: [String: String], startDate: Date) throws -> Date {
        if let date = csvValue(row, ["date", "日期"]),
           let time = csvValue(row, ["end_time", "endtime", "结束时间", "下课时间"]) {
            return try parseCourseDate(date, time: time)
        }

        if let end = csvValue(row, ["end", "end_date", "enddatetime", "结束", "结束日期时间"]),
           let parsed = try parseAgentDate(end) {
            return parsed
        }

        if let minutesText = csvValue(row, ["duration", "duration_minutes", "时长", "分钟"]),
           let minutes = Double(minutesText) {
            return startDate.addingTimeInterval(minutes * 60)
        }

        if let range = csvPeriodRange(row),
           let period = defaultCoursePeriods.first(where: { $0.id == range.upperBound }) {
            return dateForCoursePeriod(period, on: startDate, useEndTime: true)
        }

        return startDate.addingTimeInterval(60 * 60)
    }

    private func courseRecurrenceEndDate(from row: [String: String]) throws -> Date? {
        try parseCSVDateOnly(csvValue(row, ["repeat_until", "until", "term_end", "semester_end", "学期结束", "结束周日期"]))
    }

    private func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()

        while let char = iterator.next() {
            switch char {
            case "\"":
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field); field = ""
                        } else if next == "\n" {
                            row.append(field); rows.append(row); row = []; field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            case "," where !inQuotes:
                row.append(field); field = ""
            case "\n" where !inQuotes:
                row.append(field); rows.append(row); row = []; field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(char)
            }
        }

        row.append(field)
        rows.append(row)
        return rows
    }

    private func normalizeCSVHeader(_ header: String) -> String {
        header
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func csvValue(_ row: [String: String], _ keys: [String]) -> String? {
        for key in keys {
            let normalized = normalizeCSVHeader(key)
            if let value = row[normalized]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func csvBool(_ row: [String: String], _ keys: [String]) -> Bool? {
        guard let value = csvValue(row, keys)?.lowercased() else { return nil }
        if ["true", "yes", "1", "y", "是"].contains(value) { return true }
        if ["false", "no", "0", "n", "否"].contains(value) { return false }
        return nil
    }

    private func csvWeekday(_ row: [String: String], _ keys: [String]) -> Int? {
        guard let raw = csvValue(row, keys)?.lowercased() else { return nil }
        let map: [String: Int] = [
            "sun": 1, "sunday": 1, "日": 1, "周日": 1, "星期日": 1, "7": 1,
            "mon": 2, "monday": 2, "一": 2, "周一": 2, "星期一": 2, "1": 2,
            "tue": 3, "tuesday": 3, "二": 3, "周二": 3, "星期二": 3, "2": 3,
            "wed": 4, "wednesday": 4, "三": 4, "周三": 4, "星期三": 4, "3": 4,
            "thu": 5, "thursday": 5, "四": 5, "周四": 5, "星期四": 5, "4": 5,
            "fri": 6, "friday": 6, "五": 6, "周五": 6, "星期五": 6, "5": 6,
            "sat": 7, "saturday": 7, "六": 7, "周六": 7, "星期六": 7, "6": 7
        ]
        return map[raw]
    }

    private func csvPeriodRange(_ row: [String: String]) -> ClosedRange<Int>? {
        if let start = csvInt(row, ["period_start", "start_period", "section_start", "起始节", "开始节", "第几节"]),
           let end = csvInt(row, ["period_end", "end_period", "section_end", "结束节"]) {
            return min(start, end)...max(start, end)
        }

        guard let raw = csvValue(row, ["period", "periods", "section", "sections", "节次", "课节"]) else { return nil }
        let normalized = raw
            .replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: "节", with: "")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "~", with: "-")
        let parts = normalized.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let first = parts.first, let last = parts.last {
            return min(first, last)...max(first, last)
        }
        return nil
    }

    private func csvInt(_ row: [String: String], _ keys: [String]) -> Int? {
        guard let value = csvValue(row, keys) else { return nil }
        return Int(value)
    }

    private func parseCourseDate(_ dateText: String, time: String) throws -> Date {
        if let date = try parseAgentDate("\(dateText) \(time)") { return date }
        throw APIError.httpError(400, "无法解析日期时间: \(dateText) \(time)")
    }

    private func parseCourseDate(_ date: Date, time: String) throws -> Date {
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard let hour = timeParts.first else {
            throw APIError.httpError(400, "无法解析时间: \(time)")
        }
        var components = DateComponents()
        components.year = dateComponents.year
        components.month = dateComponents.month
        components.day = dateComponents.day
        components.hour = hour
        components.minute = timeParts.dropFirst().first ?? 0
        guard let result = calendar.date(from: components) else {
            throw APIError.httpError(400, "无法解析时间: \(time)")
        }
        return result
    }

    private func dateForCoursePeriod(_ period: CoursePeriod, on date: Date, useEndTime: Bool) -> Date {
        let calendar = Calendar.current
        let base = calendar.dateComponents([.year, .month, .day], from: date)
        var components = DateComponents()
        components.year = base.year
        components.month = base.month
        components.day = base.day
        components.hour = useEndTime ? period.endHour : period.startHour
        components.minute = useEndTime ? period.endMinute : period.startMinute
        return calendar.date(from: components) ?? date
    }

    private func parseCSVDateOnly(_ text: String?) throws -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try parseAgentDate(text) { return date }
        return nil
    }

    private func dateForNext(weekday: Int, onOrAfter date: Date) -> Date {
        let calendar = Calendar.current
        let current = calendar.component(.weekday, from: date)
        let offset = (weekday - current + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: date) ?? date
    }
}


// --- Merged from ChatViewModel+Engine.swift ---


extension ChatViewModel {
    // MARK: - JSON Schema and Argument Parsing

    internal func objectSchema(properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    internal func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    internal func boolSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    internal func stringArg(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] else { return nil }
        if value is NSNull { return nil }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal func boolArg(_ args: [String: Any], _ key: String) -> Bool? {
        if let bool = args[key] as? Bool { return bool }
        if let number = args[key] as? NSNumber { return number.boolValue }
        if let string = args[key] as? String {
            return ["true", "yes", "1", "是"].contains(string.lowercased())
        }
        return nil
    }

    internal func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let int = args[key] as? Int { return int }
        if let number = args[key] as? NSNumber { return number.intValue }
        if let string = args[key] as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    internal func stringArrayArg(_ args: [String: Any], _ key: String) -> [String] {
        if let array = args[key] as? [String] { return array }
        if let array = args[key] as? [Any] {
            return array.compactMap { value in
                if value is NSNull { return nil }
                return String(describing: value)
            }
        }
        if let single = stringArg(args, key), !single.isEmpty {
            return [single]
        }
        return []
    }

    internal func dictionaryArrayArg(_ args: [String: Any], _ key: String) -> [[String: Any]] {
        if let array = args[key] as? [[String: Any]] { return array }
        if let array = args[key] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    internal func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal func optionalStringValue(_ value: Any?) -> String? {
        let result = stringValue(value)
        return result.isEmpty ? nil : result
    }

    internal func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "yes", "1", "是"].contains(string.lowercased())
        }
        return nil
    }

    internal func parseAgentDate(_ value: String?) throws -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "yyyy/M/d HH:mm", "yyyy/M/d HH:mm:ss", "yyyy/M/d"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }

        throw APIError.httpError(400, "无法解析日期: \(raw)")
    }

    internal func completeChatWithSkillTools(messages: [Message],
                                            conversationID: UUID,
                                            assistantID: UUID,
                                            provider: Provider,
                                            model: String,
                                            apiKey: String,
                                            depth: Int = 0,
                                            thinkingBudget: Int = 0) async throws {
        var agentMessages = messages.map { message in
            AgentMsg(role: agentRole(for: message.role), content: message.content)
        }
        let lastUserMsg = messages.last { $0.role == .user }?.content ?? ""
        let maxChatDepth = 1
        let allTools = chatTools(allowSubAgent: depth < maxChatDepth)
        let tools = filterRelevantTools(allTools, query: lastUserMsg)
        
        var finalText = ""
        var reasoningParts: [String] = []
        var toolFailureSummaries: [String] = []
        var reachedFinalAnswer = false

        let maxToolRounds = 8
        for _ in 0..<maxToolRounds {
            try Task.checkCancellation()
            let currentMode = conversations.first(where: { $0.id == conversationID })?.agentMode ?? .normal
            let mainStepTitle = currentMode == .subAgent ? "Main planner" : "主 Agent"
            setChatAgentStep(depth == 0 ? mainStepTitle : "Sub-agent", status: .running, detail: depth == 0 ? "正在判断是否拆解/调用工具" : "正在执行子任务")
            isChatThinking = true
            let response = try await agentComplete(
                messages: agentMessages, tools: tools,
                provider: provider, model: model, apiKey: apiKey,
                thinkingBudget: thinkingBudget
            )
            isChatThinking = false
            try Task.checkCancellation()
            if let reasoning = response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                reasoningParts.append(reasoning)
                updateChatReasoning(conversationID: conversationID, messageID: assistantID, content: reasoningParts.joined(separator: "\n\n"))
            }

            if let calls = response.toolCalls, !calls.isEmpty {
                let skippedToolReasons = skippedChatToolReasons(for: calls)
                agentMessages.append(AgentMsg(
                    role: .assistant,
                    content: response.text,
                    reasoningContent: response.reasoningContent,
                    toolCalls: calls
                ))

                let callsRequiringConfirmation = calls.filter { skippedToolReasons[$0.id] == nil && chatToolRequiresConfirmation($0) }
                var rejectedSensitiveToolIDs = Set<String>()
                if callsRequiringConfirmation.isEmpty {
                    activeToolStatus = "正在使用工具…"
                    updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "正在使用工具…")
                } else {
                    activeToolStatus = "等待确认…"
                    updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "等待你确认本机工具调用…")
                    let approved = await confirmChatToolCalls(callsRequiringConfirmation, conversationID: conversationID)
                    if approved {
                        updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "正在使用已允许的工具…")
                    } else {
                        rejectedSensitiveToolIDs = Set(callsRequiringConfirmation.map(\.id))
                        updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "已取消本机工具，其他工具继续执行…")
                    }
                }

                let plannedCalls = calls.map { call -> (ToolCall, String, String?, Int, ChatListPayload?) in
                    if skippedToolReasons[call.id] != nil {
                        return (call, chatToolDisplayName(call.name), nil, 0, nil)
                    }
                    if call.name == "delegate_to_subagent", depth < maxChatDepth {
                        let task = stringArg(call.args, "task") ?? ""
                        let requested = intArg(call.args, "thinking_budget_tokens") ?? 0
                        let title = nextSubAgentStepTitle()
                        appendChatAgentStep(
                            title: title,
                            status: .running,
                            detail: ChaoxingTextNormalizer.preview(task.isEmpty ? "子任务" : task, limit: 44)
                        )
                        return (call, title, task, requested, nil)
                    }
                    if call.name == "make_list" {
                        let payload = makeChatListPayload(from: call)
                        setChatAgentStep("make_list", status: .running, detail: payload.title)
                        return (call, "make_list", nil, 0, payload)
                    }
                    setChatAgentStep(call.name, status: .running, detail: "工具调用中")
                    return (call, call.name, nil, 0, nil)
                }

                let scheduleToolNames = Set(scheduleModeEnabled ? harness.tools.map(\.name) : [])
                let toolResults = await withTaskGroup(of: (Int, AgentMsg, String, Bool, String, ChatListPayload?, SchedulePayload?).self) { group in
                    for (idx, planned) in plannedCalls.enumerated() {
                        group.addTask { [call = planned.0, stepTitle = planned.1, delegatedTask = planned.2, requested = planned.3, listPayload = planned.4, scheduleToolNames, rejectedSensitiveToolIDs, skippedToolReasons] in
                            if let reason = skippedToolReasons[call.id] {
                                return (idx, AgentMsg(role: .tool, content: "已跳过工具调用：\(reason)", toolCallID: call.id, toolName: call.name), stepTitle, false, "已限流跳过", nil, nil)
                            }
                            if rejectedSensitiveToolIDs.contains(call.id) {
                                return (idx, AgentMsg(role: .tool, content: "用户拒绝了本次本机工具调用。请不用这个工具继续回答，或说明为什么无法完成。", toolCallID: call.id, toolName: call.name), stepTitle, false, "用户已取消", nil, nil)
                            }
                            if call.name == "make_list", let listPayload {
                                return (idx, AgentMsg(role: .tool, content: "已绘制原生列表 UI：\(listPayload.title)，共 \(listPayload.items.count) 项。", toolCallID: call.id, toolName: call.name), stepTitle, true, "\(listPayload.items.count) 项", listPayload, nil)
                            }
                            if call.name == "delegate_to_subagent", depth < maxChatDepth {
                                let subBudget = thinkingBudget > 0 ? min(max(requested, 0), thinkingBudget) : 0
                                guard let task = delegatedTask, !task.isEmpty else {
                                    return (idx, AgentMsg(role: .tool, content: "错误: 缺少 task 参数。", toolCallID: call.id, toolName: call.name), stepTitle, false, "缺少 task 参数", nil, nil)
                                }
                                let subResult = await self.runChatSubAgent(
                                    task: task,
                                    stepTitle: stepTitle,
                                    conversationID: conversationID,
                                    assistantID: assistantID,
                                    provider: provider,
                                    model: model,
                                    apiKey: apiKey,
                                    thinkingBudget: subBudget
                                )
                                return (idx, AgentMsg(role: .tool, content: subResult, toolCallID: call.id, toolName: call.name), stepTitle, !subResult.hasPrefix("错误:"), subResult.hasPrefix("错误:") ? "子 Agent 失败" : "子 Agent 已返回结果", nil, nil)
                            }
                            if scheduleToolNames.contains(call.name) {
                                let result = await self.runScheduleToolFromChat(call, conversationID: conversationID)
                                return (idx, AgentMsg(role: .tool, content: result.content, toolCallID: call.id, toolName: call.name), stepTitle, !result.content.hasPrefix("错误:"), ChaoxingTextNormalizer.preview(result.content, limit: 44), nil, result.payload)
                            }
                            let result = await self.runChatToolDetailed(call, conversationID: conversationID)
                            return (idx, AgentMsg(role: .tool, content: result.content, toolCallID: call.id, toolName: call.name), stepTitle, !result.content.hasPrefix("错误:"), ChaoxingTextNormalizer.preview(result.content, limit: 44), result.listPayload, nil)
                        }
                    }

                    var results: [(Int, AgentMsg, String, Bool, String, ChatListPayload?, SchedulePayload?)] = []
                    for await result in group {
                        results.append(result)
                        activeToolStatus = result.3 ? "已完成：\(result.2)" : "已失败：\(result.2)"
                        setChatAgentStep(result.2, status: result.3 ? .done : .failed, detail: result.4)
                        if !result.3 {
                            toolFailureSummaries.append("\(result.2): \(result.4)")
                        }
                        if let payload = result.5 {
                            updateChatListPayload(conversationID: conversationID, messageID: assistantID, payload: payload)
                        }
                        if let payload = result.6 {
                            updateChatSchedulePayload(conversationID: conversationID, messageID: assistantID, payload: payload)
                        }
                    }
                    activeToolStatus = ""
                    return results.sorted { $0.0 < $1.0 }
                }
                agentMessages.append(contentsOf: toolResults.map(\.1))
            } else {
                finalText = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                reachedFinalAnswer = true
                if isBareCompletionText(finalText), !toolFailureSummaries.isEmpty {
                    finalText = partialFailureSummary(toolFailureSummaries)
                }
                let succeeded = toolFailureSummaries.isEmpty || !isBareCompletionText(finalText)
                setChatAgentStep(depth == 0 ? mainStepTitle : "Sub-agent", status: succeeded ? .done : .failed, detail: succeeded ? "回答已生成" : "存在失败工具")
                if currentMode == .subAgent {
                    setChatAgentStep("Summary", status: .done, detail: "已综合子任务结果")
                }
                break
            }
        }

        if finalText.isEmpty {
            if !toolFailureSummaries.isEmpty {
                finalText = partialFailureSummary(toolFailureSummaries)
                let currentMode = conversations.first(where: { $0.id == conversationID })?.agentMode ?? .normal
                if currentMode == .subAgent {
                    setChatAgentStep("Summary", status: .failed, detail: "存在失败子任务")
                }
            } else if reachedFinalAnswer {
                finalText = "模型没有返回可显示的最终回答。"
            } else {
                finalText = "任务未完成：Agent 达到工具调用轮次上限，但没有生成最终回答。"
                let currentMode = conversations.first(where: { $0.id == conversationID })?.agentMode ?? .normal
                if currentMode == .subAgent {
                    setChatAgentStep("Summary", status: .failed, detail: "达到轮次上限")
                }
            }
        }
        updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: finalText)
        if !reasoningParts.isEmpty {
            updateChatReasoning(conversationID: conversationID, messageID: assistantID, content: reasoningParts.joined(separator: "\n\n"))
        }
    }

    // MARK: - Tool Runner

    internal func runChatTool(_ call: ToolCall, conversationID: UUID) async -> String {
        await runChatToolDetailed(call, conversationID: conversationID).content
    }

    internal func runChatToolDetailed(_ call: ToolCall, conversationID: UUID) async -> ChatToolRunResult {
        switch call.name {
        case "make_list":
            let payload = makeChatListPayload(from: call)
            return ChatToolRunResult("已绘制原生列表 UI：\(payload.title)，共 \(payload.items.count) 项。", listPayload: payload)
        case "web_search":
            return ChatToolRunResult(await runWebSearchTool(call))
        case "web_fetch":
            return ChatToolRunResult(await runWebFetchTool(call))
        case "read_pdf":
            return ChatToolRunResult(runReadPDFTool(call))
        case "search_apple_notes":
            return ChatToolRunResult(runSearchAppleNotesTool(call))
        case "create_apple_note":
            return ChatToolRunResult(runCreateAppleNoteTool(call))
        case "add_shopping_items":
            return runAddShoppingItemsTool(call)
        case "list_shopping_items":
            return runListShoppingItemsTool(call)
        case "complete_shopping_item":
            return runCompleteShoppingItemTool(call)
        case "delete_shopping_item":
            return runDeleteShoppingItemTool(call)
        case "run_skill_script":
            return ChatToolRunResult(await runChatSkillTool(call))
        default:
            if scheduleModeEnabled && harness.tools.contains(where: { $0.name == call.name }) {
                let result = await runScheduleToolFromChat(call, conversationID: conversationID)
                return ChatToolRunResult(result.content)
            }
            return ChatToolRunResult("错误: 未知工具 \(call.name)")
        }
    }

    private func makeChatListPayload(from call: ToolCall) -> ChatListPayload {
        let title = stringArg(call.args, "title") ?? "列表"
        let subtitle = stringArg(call.args, "subtitle")
        let style = stringArg(call.args, "style") ?? "default"
        let objectItems = dictionaryArrayArg(call.args, "items").compactMap { dict -> ChatListItem? in
            guard let title = dict["title"] as? String else { return nil }
            return ChatListItem(
                title: title,
                detail: dict["detail"] as? String,
                badge: dict["badge"] as? String,
                priority: dict["priority"] as? String,
                isDone: dict["isDone"] as? Bool
            )
        }
        let items = objectItems.isEmpty
            ? stringArrayArg(call.args, "items").map { ChatListItem(title: $0) }
            : objectItems
        return ChatListPayload(title: title, subtitle: subtitle, style: style, items: items)
    }

    // MARK: - Sub-Agent Runner

    private func runChatSubAgent(task: String,
                                stepTitle: String,
                                conversationID: UUID,
                                assistantID: UUID,
                                provider: Provider,
                                model: String,
                                apiKey: String,
                                thinkingBudget: Int = 0) async -> String {
        var subHistory: [AgentMsg] = [
            AgentMsg(role: .system, content: """
            You are a specialized sub-agent for: \(task)
            
            Focus ONLY on this task. Use available tools if needed. Return a detailed final report including key facts and data.
            If you used tools, summarize what you found/did precisely.
            """),
            AgentMsg(role: .system, content: dynamicEnvironmentContext(for: conversations.first { $0.id == conversationID } ?? Conversation(providerID: provider.id, model: model), now: Date())),
            AgentMsg(role: .user, content: task)
        ]
        
        var toolLogEntries: [String] = []
        let subTools = chatTools(allowSubAgent: false)
        
        do {
            for round in 0..<4 {
                try Task.checkCancellation()
                setChatAgentStep(stepTitle, status: .running, detail: "第 \(round + 1) 轮思考中")
                
                let response = try await withChatTimeout(seconds: 45, label: "\(stepTitle) 模型调用") { [subHistory] in
                    try await agentComplete(
                        messages: subHistory,
                        tools: subTools,
                        provider: provider,
                        model: model,
                        apiKey: apiKey,
                        thinkingBudget: thinkingBudget
                    )
                }
                
                // Collect reasoning for the log
                if let reasoning = response.reasoningContent, !reasoning.isEmpty {
                    toolLogEntries.append("[第 \(round + 1) 轮思考]: \(ChaoxingTextNormalizer.preview(reasoning, limit: 300))")
                }
                
                if let calls = response.toolCalls, !calls.isEmpty {
                    setChatAgentStep(stepTitle, status: .running, detail: "正在使用 \(calls.count) 个工具")
                    
                    // Add assistant response to sub-history
                    subHistory.append(AgentMsg(role: .assistant, content: response.text, reasoningContent: response.reasoningContent, toolCalls: calls))
                    
                    var failedTools: [String] = []
                    for call in calls {
                        try Task.checkCancellation()
                        setChatAgentStep(stepTitle, status: .running, detail: "工具：\(chatToolDisplayName(call.name))")
                        
                        let result = try await withChatTimeout(seconds: 25, label: "\(stepTitle) 工具 \(call.name)") {
                            await self.runChatTool(call, conversationID: conversationID)
                        }
                        
                        if result.hasPrefix("错误:") {
                            failedTools.append("\(chatToolDisplayName(call.name)): \(ChaoxingTextNormalizer.preview(result, limit: 80))")
                        } else {
                            let argsString = String(describing: call.args)
                            toolLogEntries.append("- 调用工具 \(call.name) (参数: \(ChaoxingTextNormalizer.preview(argsString, limit: 60))) -> 成功返回内容预览: \(ChaoxingTextNormalizer.preview(result, limit: 120))")
                        }
                        
                        // Add tool result to sub-history
                        subHistory.append(AgentMsg(role: .tool, content: result, toolCallID: call.id, toolName: call.name))
                    }
                    
                    if !failedTools.isEmpty {
                        setChatAgentStep(stepTitle, status: .failed, detail: "工具失败")
                        return partialFailureSummary(failedTools)
                    }
                } else {
                    let textResult = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !textResult.isEmpty || !toolLogEntries.isEmpty else {
                        setChatAgentStep(stepTitle, status: .failed, detail: "空结果")
                        return "错误: 子 Agent 没有生成有效结果。"
                    }
                    setChatAgentStep(stepTitle, status: .done, detail: "子 Agent 已返回结果")
                    
                    let executionLog = toolLogEntries.joined(separator: "\n")
                    let finalReport = """
                    [子任务执行记录]
                    \(executionLog.isEmpty ? "（无工具调用，仅通过逻辑推断生成）" : executionLog)

                    [结论]
                    \(textResult.isEmpty ? "（见执行记录中的工具返回内容）" : textResult)
                    """
                    return finalReport
                }
            }
            setChatAgentStep(stepTitle, status: .failed, detail: "达到轮次上限")
            let log = toolLogEntries.joined(separator: "\n")
            return "错误: 子 Agent 达到轮次上限，未生成最终结论。\n\n[执行记录]:\n\(ChaoxingTextNormalizer.preview(log, limit: 1200))"
        } catch {
            if isCancellationError(error) { return "（已取消）" }
            setChatAgentStep(stepTitle, status: .failed, detail: error.localizedDescription)
            return "错误: 子 Agent 失败——\(error.localizedDescription)"
        }
    }

    // MARK: - Tool Helpers

    private func isBareCompletionText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ "))
            .lowercased()
        return ["完成", "done", "ok", "好的", "已完成"].contains(normalized)
    }

    private func partialFailureSummary(_ failures: [String]) -> String {
        let unique = Array(NSOrderedSet(array: failures).compactMap { $0 as? String }).prefix(4)
        return """
        任务没有完全完成：有 \(failures.count) 个工具或子任务失败。
        \(unique.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func agentRole(for role: MessageRole) -> AgentMsg.Role {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        }
    }

    private func updateChatPlaceholder(conversationID: UUID, messageID: UUID, content: String) {
        mutateConversationMessage(conversationID: conversationID, messageID: messageID) { message in
            message.content = content
        }
    }

    private func chatTools(allowSubAgent: Bool = false) -> [AgentTool] {
        var tools: [AgentTool] = []
        tools.append(makeListTool())
        if webAccessEnabled {
            tools.append(contentsOf: webTools())
        }
        if scheduleModeEnabled {
            tools.append(contentsOf: harness.tools)
        }
        if pdfToolEnabled {
            tools.append(readPDFTool())
        }
        if appleNotesToolEnabled {
            tools.append(contentsOf: appleNotesTools())
        }
        if shoppingListToolEnabled {
            tools.append(contentsOf: shoppingListTools())
        }
        if hasRunnableChatSkillScripts {
            tools.append(AgentTool(
                name: "run_skill_script",
                description: """
                Run a script bundled inside an enabled chat Skill. This is sandboxed: network is allowed, but user-directory reads are blocked and writes are restricted to the temporary working directory. Use only listed skill_name and script_path values.

                Available scripts:
                \(runnableChatSkillScripts.flatMap { skill in skill.scripts.map { "- skill_name=\(skill.name), script_path=\($0.relativePath), language=\($0.language)" } }.joined(separator: "\n"))
                """,
                parameters: objectSchema(properties: [
                    "skill_name": stringSchema("Enabled skill name exactly as listed."),
                    "script_path": stringSchema("Script relative path exactly as listed, for example scripts/analyze.py."),
                    "input": stringSchema("Optional stdin text passed to the script."),
                    "args": [
                        "type": "array",
                        "description": "Optional command-line arguments. Values are passed as literal strings.",
                        "items": ["type": "string"]
                    ],
                    "timeout_seconds": [
                        "type": "integer",
                        "description": "Optional timeout from 1 to 20 seconds. Defaults to 8."
                    ]
                ], required: ["skill_name", "script_path"])
            ))
        }
        if allowSubAgent {
            tools.append(AgentTool(
                name: "delegate_to_subagent",
                description: """
                Main agent can delegate a complex task to a specialized sub-agent.
                The sub-agent has the same tool-set but focusing on a specific part.
                Use this to parallelize tasks or deep-dive into a specific topic.
                The result will be returned as a detailed report.
                """,
                parameters: objectSchema(properties: [
                    "task": stringSchema("Precise task for the sub-agent."),
                    "thinking_budget_tokens": [
                        "type": "integer",
                        "description": "Optional thinking token budget for this sub-task."
                    ]
                ], required: ["task"])
            ))
        }
        return tools
    }

    private func runScheduleToolFromChat(_ call: ToolCall, conversationID: UUID) async -> SkillResult {
        refreshRemindersAccess()
        refreshCalendarAccess()
        let result = await harness.runTool(call, context: buildSkillContext(now: Date(), conversationID: conversationID))
        
        await refreshScheduleSidebar()
        return result
    }

    private func makeListTool() -> AgentTool {
        AgentTool(
            name: "make_list",
            description: "Render a compact list in the chat UI.",
            parameters: objectSchema(properties: [
                "title": stringSchema("List title."),
                "subtitle": stringSchema("Optional short subtitle."),
                "style": stringSchema("Optional visual style: default, success, warning, danger, info."),
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": stringSchema("Item title."),
                            "detail": stringSchema("Optional item detail."),
                            "badge": stringSchema("Optional small badge text."),
                            "priority": stringSchema("Optional priority label."),
                            "isDone": boolSchema("Whether the item is already done.")
                        ],
                        "required": ["title"],
                        "additionalProperties": false
                    ]
                ]
            ], required: ["items"])
        )
    }

    private func webTools() -> [AgentTool] {
        [
            AgentTool(
                name: "web_search",
                description: "Search public web pages for current or external information. Use for 用户要求搜索/查找/联网/最新信息, or when local knowledge may be stale.",
                parameters: objectSchema(properties: [
                    "query": stringSchema("Search query."),
                    "max_results": [
                        "type": "integer",
                        "description": "Maximum results to return, 1-5. Defaults to 5."
                    ]
                ], required: ["query"])
            ),
            AgentTool(
                name: "web_fetch",
                description: "Fetch and extract text from a public http/https URL. Use after search or when the user gives a web link.",
                parameters: objectSchema(properties: [
                    "url": stringSchema("Public http/https URL to read.")
                ], required: ["url"])
            )
        ]
    }

    private func readPDFTool() -> AgentTool {
        AgentTool(
            name: "read_pdf",
            description: "Read text from a PDF path.",
            parameters: objectSchema(properties: [
                "path": stringSchema("PDF file path."),
                "start_page": [
                    "type": "integer",
                    "description": "1-based page number to start reading from. Defaults to 1."
                ],
                "max_pages": [
                    "type": "integer",
                    "description": "Maximum pages to read, 1-40. Defaults to 12."
                ],
                "max_chars": [
                    "type": "integer",
                    "description": "Maximum returned characters, 1000-40000. Defaults to 18000."
                ]
            ], required: ["path"])
        )
    }

    private func appleNotesTools() -> [AgentTool] {
        [
            AgentTool(
                name: "search_apple_notes",
                description: "Search Apple Notes on this Mac. This is a sensitive local tool and should only be used when the user explicitly asks to search/read notes or memo content.",
                parameters: objectSchema(properties: [
                    "query": stringSchema("Keyword to search in note titles and bodies."),
                    "max_results": [
                        "type": "integer",
                        "description": "Maximum notes to return, 1-10. Defaults to 5."
                    ],
                    "include_body": boolSchema("Whether to include full note body. Defaults to false.")
                ], required: ["query"])
            ),
            AgentTool(
                name: "create_apple_note",
                description: "Create a new Apple Note on this Mac. Use only when the user explicitly asks to write a memo/note.",
                parameters: objectSchema(properties: [
                    "title": stringSchema("Note title."),
                    "body": stringSchema("Note body.")
                ], required: ["title", "body"])
            )
        ]
    }

    private func shoppingListTools() -> [AgentTool] {
        [
            AgentTool(name: "add_shopping_items", description: "Add items to the shopping list.", parameters: objectSchema(properties: ["items": ["type": "array", "items": ["type": "object", "properties": ["title": stringSchema("Item name."), "quantity": stringSchema("Optional quantity."), "note": stringSchema("Optional note.")], "required": ["title"], "additionalProperties": false]]], required: ["items"])),
            AgentTool(name: "list_shopping_items", description: "List shopping items.", parameters: objectSchema(properties: ["include_done": ["type": "boolean"]])),
            AgentTool(name: "complete_shopping_item", description: "Mark a shopping item done.", parameters: objectSchema(properties: ["id": stringSchema("Item id."), "title": stringSchema("Item title.")])),
            AgentTool(name: "delete_shopping_item", description: "Delete a shopping item.", parameters: objectSchema(properties: ["id": stringSchema("Item id."), "title": stringSchema("Item title.")]))
        ]
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func runAppleScript(_ source: String, failurePrefix: String) -> String {
        guard let script = NSAppleScript(source: source) else {
            return "\(failurePrefix): 脚本无效。"
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            return "\(failurePrefix): \(error)"
        }
        return output.stringValue ?? "完成。"
    }

    private func withChatTimeout<T>(
        seconds: Double,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ChatTimeoutError(label: label, seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw ChatTimeoutError(label: label, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    private struct ChatTimeoutError: LocalizedError {
        let label: String
        let seconds: Double

        var errorDescription: String? {
            "\(label) 超时（\(Int(seconds)) 秒）"
        }
    }

    // MARK: - Tool Implementation

    private func runReadPDFTool(_ call: ToolCall) -> String {
        guard pdfToolEnabled else { return "错误: PDF 工具未启用。" }
        guard let rawPath = stringArg(call.args, "path"), !rawPath.isEmpty else {
            return "错误: 缺少 PDF 路径。"
        }
        let startPage = max(intArg(call.args, "start_page") ?? 1, 1)
        let maxPages = min(max(intArg(call.args, "max_pages") ?? 12, 1), 40)
        let maxChars = min(max(intArg(call.args, "max_chars") ?? 18_000, 1_000), 40_000)

        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.pathExtension.lowercased() == "pdf" else {
            return "错误: 只能读取 .pdf 文件。"
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "错误: 文件不存在：\(url.path)"
        }
        guard let document = PDFDocument(url: url) else {
            return "错误: 无法打开 PDF，文件可能损坏或受保护。"
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return "错误: PDF 没有可读取页面。" }
        let firstIndex = min(startPage - 1, pageCount - 1)
        let lastIndex = min(firstIndex + maxPages - 1, pageCount - 1)
        var chunks: [String] = []
        for index in firstIndex...lastIndex {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                chunks.append("## 第 \(index + 1) 页\n\(text)")
            }
        }
        guard !chunks.isEmpty else {
            return "PDF 已打开，但指定页范围没有可抽取文本；它可能是扫描版图片 PDF。"
        }
        let joined = chunks.joined(separator: "\n\n")
        let truncated = joined.count > maxChars
            ? String(joined.prefix(maxChars)) + "\n\n[PDF 文本已截断，原始抽取约 \(joined.count) 字符]"
            : joined
        return """
        PDF: \(url.lastPathComponent)
        路径: \(url.path)
        页数: \(pageCount)，本次读取: \(firstIndex + 1)-\(lastIndex + 1)

        \(truncated)
        """
    }

    private func runSearchAppleNotesTool(_ call: ToolCall) -> String {
        guard appleNotesToolEnabled else { return "错误: Apple Notes 工具未启用。" }
        guard let query = stringArg(call.args, "query"), !query.isEmpty else {
            return "错误: 缺少搜索关键词。"
        }
        let maxResults = min(max(intArg(call.args, "max_results") ?? 5, 1), 10)
        let includeBody = boolArg(call.args, "include_body") ?? false
        let queryScript = appleScriptLiteral(query)
        let source = """
        set searchText to \(queryScript)
        set maxResults to \(maxResults)
        set includeBody to \(includeBody ? "true" : "false")
        set outputText to ""
        set foundCount to 0
        tell application "Notes"
            repeat with targetAccount in accounts
                repeat with targetFolder in folders of targetAccount
                    repeat with targetNote in notes of targetFolder
                        set noteName to name of targetNote as text
                        set noteBody to body of targetNote as text
                        if noteName contains searchText or noteBody contains searchText then
                            set foundCount to foundCount + 1
                            set outputText to outputText & "### " & noteName & linefeed
                            set outputText to outputText & "Folder: " & (name of targetFolder as text) & linefeed
                            if includeBody then
                                set outputText to outputText & noteBody & linefeed & linefeed
                            else
                                set snippetLength to 500
                                if (length of noteBody) > snippetLength then
                                    set outputText to outputText & (text 1 thru snippetLength of noteBody) & "..." & linefeed & linefeed
                                else
                                    set outputText to outputText & noteBody & linefeed & linefeed
                                end if
                            end if
                            if foundCount >= maxResults then return outputText
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        if outputText is "" then
            return "未找到匹配的 Apple Notes。"
        else
            return outputText
        end if
        """
        return runAppleScript(source, failurePrefix: "Apple Notes 搜索失败")
    }

    private func runCreateAppleNoteTool(_ call: ToolCall) -> String {
        guard appleNotesToolEnabled else { return "错误: Apple Notes 工具未启用。" }
        guard let title = stringArg(call.args, "title"),
              let body = stringArg(call.args, "body") else {
            return "错误: 缺少 title 或 body。"
        }
        let titleScript = appleScriptLiteral(title)
        let bodyScript = appleScriptLiteral(body)
        let source = """
        tell application "Notes"
            tell default account
                make new note at folder "Notes" with properties {name:\(titleScript), body:\(bodyScript)}
            end tell
        end tell
        return "Note created successfully."
        """
        return runAppleScript(source, failurePrefix: "Apple Notes 创建失败")
    }

    private func runChatSkillTool(_ call: ToolCall) async -> String {
        guard let skillName = stringArg(call.args, "skill_name"),
              let scriptPath = stringArg(call.args, "script_path") else {
            return "错误: 缺少 skill_name 或 script_path。"
        }
        guard let skill = runnableChatSkillScripts.first(where: { $0.name == skillName }) else {
            return "错误: Skill 未启用或不存在。"
        }
        guard let script = skill.scripts.first(where: { $0.relativePath == scriptPath || $0.name == scriptPath }) else {
            return "错误: 该 Skill 没有这个脚本。"
        }

        let args = stringArrayArg(call.args, "args")
        let input = stringArg(call.args, "input")
        let timeout = min(max(intArg(call.args, "timeout_seconds") ?? 8, 1), 20)

        do {
            return try await runSkillScriptInSandbox(skill: skill, script: script, args: args, input: input, timeout: timeout)
        } catch {
            return "错误: \(error.localizedDescription)"
        }
    }

    private func runSkillScriptInSandbox(skill: ChatSkill,
                                         script: ChatSkillScript,
                                         args: [String],
                                         input: String?,
                                         timeout: Int) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .resolvingSymlinksInPath()
                .appendingPathComponent("ChatBotSkillSandbox", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: root)
            }

            let scriptURL = root.appendingPathComponent(script.name)
            try script.content.write(to: scriptURL, atomically: true, encoding: .utf8)

            let profileURL = root.appendingPathComponent("sandbox.sb")
            try Self.sandboxProfile(for: root.path).write(to: profileURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.currentDirectoryURL = root
            process.environment = [
                "HOME": root.path,
                "TMPDIR": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]

            var commandArgs = ["-f", profileURL.path]
            let interpreter = Self.interpreterCommand(for: script)
            commandArgs.append(interpreter.executable)
            commandArgs.append(contentsOf: interpreter.arguments)
            commandArgs.append(scriptURL.path)
            commandArgs.append(contentsOf: args)

            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = commandArgs

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            var timedOut = false
            let timeoutWork = DispatchWorkItem {
                timedOut = true
                if process.isRunning {
                    process.terminate()
                }
            }

            try process.run()
            if let input, let data = input.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            stdin.fileHandleForWriting.closeFile()

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWork)
            process.waitUntilExit()
            timeoutWork.cancel()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = [
                output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "stdout:\n\(output)",
                errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "stderr:\n\(errorOutput)"
            ].compactMap { $0 }.joined(separator: "\n\n")

            let status = timedOut ? "timed out after \(timeout)s" : "exit \(process.terminationStatus)"
            let body = combined.isEmpty ? "(no output)" : combined
            return """
            Skill script result
            skill: \(skill.name)
            script: \(script.relativePath)
            sandbox: temporary working directory, network allowed, user directories blocked
            status: \(status)

            \(String(body.prefix(12_000)))
            """
        }.value
    }

    private func runWebSearchTool(_ call: ToolCall) async -> String {
        guard let query = stringArg(call.args, "query"), !query.isEmpty else {
            return "错误: 缺少 query。"
        }
        let maxResults = min(max(intArg(call.args, "max_results") ?? 5, 1), 5)

        do {
            var components = URLComponents(string: "https://duckduckgo.com/html/")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url else {
                return "错误: 搜索 URL 无效。"
            }
            let fetched = try await fetchPublicWebURL(url, maxBytes: maxWebFetchBytes)
            let results = parseDuckDuckGoResults(from: fetched.text, limit: maxResults)
            guard !results.isEmpty else {
                return """
                Web search result
                query: \(query)
                status: \(fetched.statusCode.map(String.init) ?? "unknown")

                未能解析到搜索结果。页面片段：
                \(String(normalizeFetchedText(fetched.text, contentType: fetched.contentType).prefix(4_000)))
                """
            }

            return """
            Web search result
            query: \(query)
            results:
            \(results.enumerated().map { index, result in
            """
            \(index + 1). \(result.title)
               url: \(result.url)
               snippet: \(result.snippet)
            """
            }.joined(separator: "\n"))
            """
        } catch {
            return "错误: 联网搜索失败：\(error.localizedDescription)"
        }
    }

    private func runWebFetchTool(_ call: ToolCall) async -> String {
        guard let rawURL = stringArg(call.args, "url"),
              let url = URL(string: rawURL) else {
            return "错误: URL 无效。"
        }

        do {
            let fetched = try await fetchPublicWebURL(url, maxBytes: maxWebFetchBytes)
            let text = normalizeFetchedText(fetched.text, contentType: fetched.contentType)
            return """
            Web fetch result
            url: \(fetched.finalURL.absoluteString)
            status: \(fetched.statusCode.map(String.init) ?? "unknown")
            content_type: \(fetched.contentType ?? "unknown")
            truncated: \(fetched.truncated ? "yes" : "no")

            \(String(text.prefix(14_000)))
            """
        } catch {
            return "错误: 网页读取失败：\(error.localizedDescription)"
        }
    }

    private struct WebFetchResult {
        let finalURL: URL
        let statusCode: Int?
        let contentType: String?
        let text: String
        let truncated: Bool
    }

    private struct WebSearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private func fetchPublicWebURL(_ url: URL, maxBytes: Int) async throws -> WebFetchResult {
        try validatePublicWebURL(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("ChatBot/1.0 (+public web fetch)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        if let finalURL = response.url {
            try validatePublicWebURL(finalURL)
        }

        var data = Data()
        var truncated = false
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= maxBytes {
                truncated = true
                break
            }
        }

        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return WebFetchResult(
            finalURL: response.url ?? url,
            statusCode: http?.statusCode,
            contentType: contentType,
            text: text,
            truncated: truncated
        )
    }

    private func validatePublicWebURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw APIError.httpError(400, "只允许 http/https URL")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw APIError.httpError(400, "URL 缺少 host")
        }
        guard !isBlockedWebHost(host) else {
            throw APIError.httpError(403, "已阻止本机、内网或保留地址：\(host)")
        }
    }

    private func isBlockedWebHost(_ host: String) -> Bool {
        let cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if cleaned == "localhost" || cleaned.hasSuffix(".localhost") || cleaned.hasSuffix(".local") {
            return true
        }
        if cleaned == "::1" || cleaned.hasPrefix("fc") || cleaned.hasPrefix("fd") || cleaned.hasPrefix("fe80") {
            return true
        }

        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let first = parts[0]
        let second = parts[1]
        if first == 0 || first == 10 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        return false
    }

    private func parseDuckDuckGoResults(from html: String, limit: Int) -> [WebSearchResult] {
        let linkPattern = #"<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#
        let snippets = regexCaptures(pattern: snippetPattern, in: html).map { captures in
            captures.first.map { cleanHTMLFragment($0) } ?? ""
        }
        let links = regexCaptures(pattern: linkPattern, in: html)

        var results: [WebSearchResult] = []
        for (index, captures) in links.enumerated() {
            guard captures.count >= 2 else { continue }
            let url = cleanDuckDuckGoURL(captures[0])
            guard URL(string: url) != nil else { continue }
            let title = cleanHTMLFragment(captures[1])
            let snippet = index < snippets.count ? snippets[index] : ""
            if !title.isEmpty {
                results.append(WebSearchResult(title: title, url: url, snippet: snippet))
            }
            if results.count >= limit { break }
        }
        return results
    }

    private func regexCaptures(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }

    private func cleanDuckDuckGoURL(_ href: String) -> String {
        var value = decodeHTMLEntities(href)
        if value.hasPrefix("//") { value = "https:\(value)" }
        if let components = URLComponents(string: value),
           components.host?.contains("duckduckgo.com") == true,
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return value
    }

    private func normalizeFetchedText(_ text: String, contentType: String?) -> String {
        let lowerType = contentType?.lowercased() ?? ""
        if lowerType.contains("html") || text.range(of: "<html", options: .caseInsensitive) != nil {
            return cleanHTMLFragment(text)
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanHTMLFragment(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<style\b[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\f\v]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    nonisolated private static func sandboxProfile(for rootPath: String) -> String {
        let escaped = rootPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write* (subpath "\(escaped)") (literal "/dev/null"))
        (deny file-read-data
          (subpath "/Users")
          (subpath "/Volumes")
          (subpath "/tmp")
          (subpath "/private/tmp")
          (subpath "/var/tmp")
          (subpath "/private/var/tmp"))
        (allow file-read-data (subpath "\(escaped)") (literal "/dev/null"))
        """
    }

    nonisolated private static func interpreterCommand(for script: ChatSkillScript) -> (executable: String, arguments: [String]) {
        switch script.fileExtension {
        case "py":
            return ("/usr/bin/python3", [])
        case "js", "mjs":
            return ("/usr/bin/env", ["node"])
        case "bash":
            return ("/bin/bash", [])
        default:
            return ("/bin/zsh", [])
        }
    }

    private func runAddShoppingItemsTool(_ call: ToolCall) -> ChatToolRunResult {
        guard shoppingListToolEnabled else { return ChatToolRunResult("错误: 购物清单工具未启用。") }
        guard let itemsArray = call.args["items"] as? [[String: Any]] else {
            return ChatToolRunResult("错误: 缺少 items 数组。")
        }
        var count = 0
        for itemDict in itemsArray {
            if let title = itemDict["title"] as? String {
                let item = ShoppingItem(
                    title: title,
                    quantity: itemDict["quantity"] as? String,
                    note: itemDict["note"] as? String
                )
                shoppingList.append(item)
                count += 1
            }
        }
        saveShoppingList()
        return ChatToolRunResult("已将 \(count) 个项目添加到购物清单。")
    }

    private func runListShoppingItemsTool(_ call: ToolCall) -> ChatToolRunResult {
        guard shoppingListToolEnabled else { return ChatToolRunResult("错误: 购物清单工具未启用。") }
        let includeDone = boolArg(call.args, "include_done") ?? false
        let filtered = includeDone ? shoppingList : shoppingList.filter { !$0.isCompleted }
        guard !filtered.isEmpty else {
            return ChatToolRunResult(includeDone ? "购物清单为空。" : "购物清单中没有未完成的项目。")
        }
        let listText = filtered.map { item in
            let status = item.isCompleted ? "[已完成] " : ""
            let qty = item.quantity.map { " (\($0))" } ?? ""
            let note = item.note.map { " - \($0)" } ?? ""
            return "- \(status)\(item.title)\(qty)\(note)"
        }.joined(separator: "\n")
        return ChatToolRunResult("当前购物清单：\n\(listText)")
    }

    private func runCompleteShoppingItemTool(_ call: ToolCall) -> ChatToolRunResult {
        guard shoppingListToolEnabled else { return ChatToolRunResult("错误: 购物清单工具未启用。") }
        let id = stringArg(call.args, "id")
        let title = stringArg(call.args, "title")
        if let idx = shoppingList.firstIndex(where: { item in
            if let id, item.id.uuidString == id { return true }
            if let title, item.title.localizedCaseInsensitiveContains(title) { return true }
            return false
        }) {
            shoppingList[idx].isCompleted = true
            saveShoppingList()
            return ChatToolRunResult("已标记“\(shoppingList[idx].title)”为完成。")
        }
        return ChatToolRunResult("未在清单中找到匹配的项目。")
    }

    private func runDeleteShoppingItemTool(_ call: ToolCall) -> ChatToolRunResult {
        guard shoppingListToolEnabled else { return ChatToolRunResult("错误: 购物清单工具未启用。") }
        let id = stringArg(call.args, "id")
        let title = stringArg(call.args, "title")
        if let idx = shoppingList.firstIndex(where: { item in
            if let id, item.id.uuidString == id { return true }
            if let title, item.title.localizedCaseInsensitiveContains(title) { return true }
            return false
        }) {
            let removed = shoppingList.remove(at: idx)
            saveShoppingList()
            return ChatToolRunResult("已从清单中删除“\(removed.title)”。")
        }
        return ChatToolRunResult("未在清单中找到匹配的项目。")
    }

    // MARK: - Prompt Generation Helpers

    internal func webAccessPrompt(isActive: Bool) -> String {
        guard isActive else { return "" }
        return """
        联网工具已启用。需要最新信息、外部事实、网页内容或用户提供 URL 时，优先使用 web_search / web_fetch；回答中保留关键来源 URL。联网工具只访问公共 http/https，不具备本地文件、localhost 或内网访问权限。
        """
    }

    internal func enabledChatSkillsPrompt() -> String {
        let enabled = chatSkills.filter { $0.isEnabled && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !enabled.isEmpty else { return "" }
        return """
        当前启用的 Agent Skills：
        这些 Skills 的 instructions 会作为能力说明使用。只有下方列出的 scripts/ 文件可以通过 run_skill_script 调用；不得请求或猜测用户本地路径，不得读取用户目录。脚本在临时沙箱中运行，允许联网，写入仅限临时工作目录。Skill 声明的 allowed-tools 不会自动授权本地文件或系统权限。

        \(enabled.map { skill in
        """
        ---
        name: \(skill.name)
        description: \(skill.description)
        ---
        \(skill.instructions)
        \(skill.scripts.isEmpty ? "" : "\n可用脚本（只能通过 run_skill_script 调用，不能请求本地路径）：\n\(skill.scripts.map { "- \($0.relativePath) (\($0.language))" }.joined(separator: "\n"))")
        """
        }.joined(separator: "\n\n"))
        """
    }

    internal func combinedChatSystemPrompt(
        for conversation: Conversation,
        modeOverride: ChatAgentMode? = nil
    ) -> String {
        let persona = conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? chatPersonaPrompt
            : conversation.systemPrompt
        let mode = modeOverride ?? conversation.agentMode
        
        let components = [
            persona,
            chatFormattingPrompt(),
            chatThinkingPrompt(),
            chatToolAwarenessPrompt(mode: mode),
            chatAgentModePrompt(mode: mode),
            chatScheduleCapabilitiesPrompt(),
            webAccessPrompt(isActive: webAccessEnabled),
            enabledChatSkillsPrompt()
        ]
        
        return components
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    
    private func chatScheduleCapabilitiesPrompt() -> String {
        guard scheduleModeEnabled else {
            return "日程模式未开启。你不能读取、管理日历、提醒事项或课程表。"
        }
        return """
        日程模式已开启。你可以使用日程工具读取或管理 macOS Reminders、Calendar、本地课程表、学习通作业和学习通 memory。
        聊天页中，任何日程工具访问都会由 App 弹出确认；其中创建、更新、完成、删除操作还会在日程工具内部再次确认具体变更。
        用户未确认前不要声称已经读取或修改。最终回答应自然、简洁。
        """
    }
    
    private func dynamicEnvironmentContext(for conversation: Conversation, now: Date) -> String {
        let tz        = TimeZone.current
        let offsetSec = tz.secondsFromGMT(for: now)
        let sign      = offsetSec >= 0 ? "+" : "-"
        let absOff    = Swift.abs(offsetSec)
        let isoOffset = String(format: "%@%02d:%02d", sign, absOff / 3600, (absOff % 3600) / 60)
        
        let cal  = Calendar.current
        let comp = cal.dateComponents(in: tz, from: now)
        let nowISO = String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@",
                            comp.year ?? 0, comp.month ?? 0, comp.day ?? 0,
                            comp.hour ?? 0, comp.minute ?? 0, comp.second ?? 0,
                            isoOffset)
        
        let wdFmt = DateFormatter()
        wdFmt.dateFormat = "EEEE"
        wdFmt.locale     = Locale(identifier: "zh_CN")
        wdFmt.timeZone   = tz
        let weekday = wdFmt.string(from: now)

        var context = """
        【当前环境上下文】
        当前时间：\(nowISO) (\(weekday))
        系统时区：\(tz.identifier) (\(isoOffset))
        """
        
        if scheduleModeEnabled {
            let scheduleContext = harness.makeTurnContextPrompt(
                now: now,
                cachedReminders: cachedAgentReminders,
                cachedEvents: cachedAgentEvents,
                hasRemindersAccess: hasRemindersAccess,
                hasCalendarAccess: hasCalendarAccess,
                courseSchedule: courseSchedule,
                importantChaoxingMessages: chaoxingMessageInsights,
                isLegacyImportedCourse: { [weak self] event in self?.isLegacyImportedCourseEvent(event) ?? false }
            )
            context += "\n\n【日程快照】\n\(scheduleContext)"
        }
        
        return context
    }

    internal func buildCompressedChatPromptMessages(
        for conversation: Conversation,
        systemPrompt: String,
        now: Date,
        persistSummary: Bool
    ) -> [Message] {
        let maxTokens = contextWindowLimit(model: conversation.model, provider: provider(for: conversation.providerID))
        let reserveTokens = max(4_000, Int(Double(maxTokens) * 0.18))
        let targetTokens = maxTokens - reserveTokens
        let recentMessageCount = 24

        var result: [Message] = []
        
        if !systemPrompt.isEmpty {
            result.append(Message(role: .system, content: systemPrompt))
        }

        if conversation.messages.count > recentMessageCount || estimateTokens(for: conversation.messages) > targetTokens {
            let olderCount = max(0, conversation.messages.count - recentMessageCount)
            let olderMessages = Array(conversation.messages.prefix(olderCount))
            let summary = makeLocalContextSummary(
                existingSummary: conversation.contextSummary,
                messages: olderMessages,
                maxChars: 7_200
            )

            if persistSummary,
               let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].contextSummary = summary
                conversations[index].contextSummaryMessageCount = olderMessages.count
                conversations[index].contextSummaryUpdatedAt = now
            }
            
            result.append(Message(role: .system, content: """
            以下是较早对话的压缩摘要，用于延续上下文：
            \(summary)
            """))
        }

        let recentMessages = Array(conversation.messages.suffix(recentMessageCount))
        result.append(contentsOf: recentMessages)
        
        let envContext = dynamicEnvironmentContext(for: conversation, now: now)
        result.append(Message(role: .system, content: envContext))
        
        return result
    }

    private func makeLocalContextSummary(existingSummary: String?, messages: [Message], maxChars: Int) -> String {
        let relevant = messages.filter { $0.role != .system }
        var lines: [String] = []
        if let existing = existingSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            lines.append("既有摘要：\(ChaoxingTextNormalizer.preview(existing, limit: maxChars / 3))")
        }
        lines.append(contentsOf: relevant.suffix(18).map { message in
            let role = message.role == .user ? "用户" : "助手"
            return "- \(role)：\(ChaoxingTextNormalizer.preview(message.content, limit: 420))"
        })
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        return String(joined.suffix(maxChars))
    }

    internal func estimateTokens(for messages: [Message]) -> Int {
        messages.reduce(0) { total, message in
            total + estimateTokens(in: message.content) + estimateTokens(in: message.reasoningContent ?? "") + 8
        }
    }

    internal func estimateTokens(in text: String) -> Int {
        var cjk = 0
        var ascii = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                cjk += 1
            case 0...127:
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { ascii += 1 }
            default:
                ascii += 1
            }
        }
        return Int((Double(cjk) / 1.6 + Double(ascii) / 4.0).rounded(.up))
    }

    internal func contextWindowLimit(model: String, provider: Provider) -> Int {
        let lower = model.lowercased()
        if lower.contains("gemini-1.5") || lower.contains("gemini-2") { return 1_000_000 }
        if lower.contains("claude") { return 200_000 }
        if lower.contains("gpt-4o") || lower.contains("gpt-4.1") || lower.contains("gpt-5") { return 128_000 }
        if lower.contains("deepseek") || lower.contains("mimo") { return 64_000 }
        if provider.apiType == .gemini { return 1_000_000 }
        return 32_000
    }

    private func chatFormattingPrompt() -> String {
        """
        输出格式偏好：默认用自然短段落回答，少用 Markdown。只有当用户明确需要清单、表格、代码、步骤文档或复杂对比时，才使用 Markdown 结构；不要把普通回答写成标题 + 多层项目符号。
        """
    }

    private func chatThinkingPrompt() -> String {
        guard deepThinkingEnabled else { return "" }
        if showReasoningSummary {
            return """
            深度思考模式已启用。回答前进行更充分的分析；最终回答可以包含一个简短的「思考摘要」，用要点说明关键判断、取舍、不确定性和必要步骤。不要输出逐字隐藏思维链、内部草稿或私密推理全文。
            """
        }
        return """
        深度思考模式已启用。回答前进行更充分的内部分析；最终只给结论、关键依据和必要步骤，不输出隐藏思维链。
        """
    }

    private func chatToolAwarenessPrompt(mode: ChatAgentMode) -> String {
        var tools = [
            "- make_list: 用原生 App UI 绘制结构化列表、待办、步骤、排序或对比项；适合替代 Markdown 清单。",
        ]
        if webAccessEnabled {
            tools.append("- web_search: 搜索公开网页，适合最新/实时/外部信息。")
            tools.append("- web_fetch: 读取公开 http/https URL 内容，适合用户给链接或搜索后打开来源。")
        }
        if scheduleModeEnabled {
            tools.append("- 日程工具: 读取/管理提醒事项、日历事件、本地课程表、学习通作业和学习通 memory。")
        }
        if pdfToolEnabled {
            tools.append("- read_pdf: 读取用户明确给出路径的本地 PDF 文本。")
        }
        if appleNotesToolEnabled {
            tools.append("- search_apple_notes/create_apple_note: 搜索、读取或创建 Apple Notes；只在用户明确要求时使用。")
        }
        if shoppingListToolEnabled {
            tools.append("- 购物清单工具: add_shopping_items/list_shopping_items/complete_shopping_item/delete_shopping_item，用于维护 App 内持久化购物清单。")
        }
        if hasRunnableChatSkillScripts {
            tools.append("- run_skill_script: 运行已启用 Chat Skill 中声明的脚本。")
        }
        if mode == .subAgent {
            tools.append("- delegate_to_subagent: main agent 拆解任务后派发 1-4 个可并行子任务，最后由 main summary。")
        }
        return """
        你可以使用以下工具完成任务：
        \(tools.joined(separator: "\n"))

        使用原则：
        - 体验优先：`make_list` 提供的是具备毛玻璃质感、支持图标和状态的原生 SwiftUI 交互组件。当信息量较大、需要对比、或者内容具备“清单/待办/步骤”属性时，你应该优先使用它来提升用户的视觉体验，而不是让用户在 Markdown 纯文本中寻找重点。
        - 场景推荐：
            - 清单型内容（如“今日任务”、“购物清单”、“功能点列表”）。
            - 步骤/流程型内容（如“操作步骤”、“安装指南”）。
            - 优先级排名（如“任务重要程度排序”）。
        - 言行一致：如果你在正文中提到“列表如下”，请务必同时发起 `make_list` 工具调用，避免口头承诺却无实际 UI 动作。
        """
    }

    private func chatAgentModePrompt(mode: ChatAgentMode) -> String {
        switch mode {
        case .normal:
            return ""
        case .multiAgent:
            return "当前启用 Multi-agent provider 并行模式：多个 provider 会先独立生成候选草稿，再由当前 provider 汇总。"
        case .subAgent:
            return """
            当前启用 Sub-agent orchestrator 模式。你是 main agent：
            1. 任务拆解：判断是否需要派发子任务。
            2. 结果综合：你会收到各子任务的详细执行记录（包括子任务调用了哪些工具、返回了哪些具体数据）。
            3. 深度汇总：你不仅要总结结论，还必须利用收到的详细数据，通过 `make_list` 等原生 UI 工具将关键信息直观地展示给用户。不要只是复述子任务的文字。
            """
        }
    }

    internal func filterRelevantTools(_ tools: [AgentTool], query: String) -> [AgentTool] {
        guard !query.isEmpty else { return tools }
        let lower = query.lowercased()
        let essential = Set(["delegate_to_subagent", "make_list"])
        
        return tools.filter { tool in
            if essential.contains(tool.name) { return true }
            if (lower.contains("搜索") || lower.contains("联网") || lower.contains("网页") || lower.contains("网站") || lower.contains("网址") || lower.contains("链接") || lower.contains("最新") || lower.contains("查一下") || lower.contains("查找")) &&
                (tool.name == "web_search" || tool.name == "web_fetch") {
                return true
            }
            if (lower.contains("pdf") || lower.contains("论文") || lower.contains("文档")) && tool.name == "read_pdf" {
                return true
            }
            if (lower.contains("备忘录") || lower.contains("备忘") || lower.contains("apple notes") || lower.contains("note")) &&
                (tool.name == "search_apple_notes" || tool.name == "create_apple_note") {
                return true
            }
            if (lower.contains("购物") || lower.contains("买") || lower.contains("采购") || lower.contains("清单")) &&
                tool.name.contains("shopping") {
                return true
            }
            if (lower.contains("今天") || lower.contains("今日") || lower.contains("明天") || lower.contains("后天") || lower.contains("本周") || lower.contains("下周") || lower.contains("日程") || lower.contains("安排") || lower.contains("事务") || lower.contains("待办") || lower.contains("ddl") || lower.contains("截止")) &&
                (tool.name.contains("reminder") || tool.name.contains("calendar") || tool.name.contains("chaoxing") || tool.name.contains("course") || tool.name.contains("memory")) {
                return true
            }
            let keywords = tool.name.components(separatedBy: "_") + [tool.description.lowercased()]
            for kw in keywords where !kw.isEmpty {
                if lower.contains(kw) { return true }
            }
            if (lower.contains("学") || lower.contains("课") || lower.contains("作业") || lower.contains("考试")) && 
                (tool.name.contains("chaoxing") || tool.name.contains("course") || tool.name.contains("memory")) {
                return true
            }
            if (lower.contains("提醒") || lower.contains("待办") || lower.contains("事项") || lower.contains("任务") || lower.contains("日历") || lower.contains("会") || lower.contains("点")) && 
                (tool.name.contains("reminder") || tool.name.contains("calendar")) {
                return true
            }
            return false
        }
    }
}


// --- Merged from ChatViewModel+Initialization.swift ---


extension ChatViewModel {
    // MARK: - Initialization & Core Helpers

    // Since we need to call super.init if it was a complicated inheritance, 
    // but here it's a root class, so we can just move the body of init.
    
    internal func bootstrap() {
        migrateUserDefaultsIfNeeded()
        loadSettings()
        loadConversations()
        loadScheduleMessages()
        loadCourseSchedule()
        loadQuickCaptures()
        loadShoppingListItems()
        loadTodayWidgetSnapshot()
        loadChaoxingMessageState()
        loadChaoxingRuntimeState()
        loadCompanionState()
        runChaoxingMemoryMaintenance()
        refreshCompanionState(reason: "init")
        startChaoxingRuntimeSyncLoop()
        refreshRemindersAccess()
        refreshCalendarAccess()
        if conversations.isEmpty { createConversation() }
        else { selectedConversationID = conversations.first?.id }
    }

    func contextWindowStats(for conversation: Conversation) -> ContextWindowStats {
        let provider = provider(for: conversation.providerID)
        let systemPrompt = combinedChatSystemPrompt(for: conversation)
        let messages = buildCompressedChatPromptMessages(
            for: conversation,
            systemPrompt: systemPrompt,
            now: Date(),
            persistSummary: false
        )
        return ContextWindowStats(
            estimatedTokens: estimateTokens(for: messages),
            maxTokens: contextWindowLimit(model: conversation.model, provider: provider),
            summarizedMessageCount: conversation.contextSummaryMessageCount ?? 0
        )
    }

    func resetSystemPromptToDefault(for convID: UUID) {
        updateSystemPrompt(chatPersonaPrompt, for: convID)
    }

    func markConversationFloating(_ id: UUID, isFloating: Bool) {
        if isFloating {
            floatingChatConversationIDs.insert(id)
        } else {
            floatingChatConversationIDs.remove(id)
        }
    }

    func isConversationFloating(_ id: UUID) -> Bool {
        floatingChatConversationIDs.contains(id)
    }

    internal func conversationMessagePosition(conversationID: UUID, messageID: UUID) -> (conversationIndex: Int, messageIndex: Int)? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        return (conversationIndex, messageIndex)
    }

    internal func mutateConversationMessage(conversationID: UUID, messageID: UUID, _ mutate: (inout Message) -> Void) {
        guard let position = conversationMessagePosition(conversationID: conversationID, messageID: messageID) else { return }
        mutate(&conversations[position.conversationIndex].messages[position.messageIndex])
        conversations[position.conversationIndex].updatedAt = Date()
    }

    internal func startChatAgentVisualization(conversationID: UUID, mode: ChatAgentMode, activeProvider: Provider, model: String) {
        guard mode != .normal else {
            chatAgentVisualization = nil
            return
        }
        let steps: [ChatAgentVisualStep]
        switch mode {
        case .normal:
            steps = []
        case .multiAgent:
            steps = multiAgentCandidateProviders(active: activeProvider).map {
                ChatAgentVisualStep(title: $0.name, detail: $0.id == activeProvider.id ? model : economicalModel(for: $0), status: .waiting)
            } + [ChatAgentVisualStep(title: "综合器", detail: "等待候选草稿", status: .waiting)]
        case .subAgent:
            steps = [
                ChatAgentVisualStep(title: "Main planner", detail: "等待规划", status: .waiting)
            ]
        }
        chatAgentVisualization = ChatAgentVisualization(
            conversationID: conversationID,
            mode: mode,
            title: mode.title,
            steps: steps
        )
    }

    internal func setChatAgentStep(_ title: String, status: ChatAgentVisualStep.Status, detail: String) {
        guard var visual = chatAgentVisualization else { return }
        if let index = visual.steps.firstIndex(where: { $0.title == title }) {
            visual.steps[index].status = status
            visual.steps[index].detail = detail
        } else {
            visual.steps.append(ChatAgentVisualStep(title: title, detail: detail, status: status))
        }
        visual.updatedAt = Date()
        chatAgentVisualization = visual
    }

    internal func appendChatAgentStep(title: String, status: ChatAgentVisualStep.Status, detail: String) {
        guard var visual = chatAgentVisualization else { return }
        visual.steps.append(ChatAgentVisualStep(title: title, detail: detail, status: status))
        visual.updatedAt = Date()
        chatAgentVisualization = visual
    }

    internal func nextSubAgentStepTitle() -> String {
        let existing = chatAgentVisualization?.steps.filter { $0.title.hasPrefix("Sub-agent") }.count ?? 0
        return "Sub-agent \(existing + 1)"
    }

    internal func markChatResponseStopped(conversationID: UUID, assistantID: UUID) {
        mutateConversationMessage(conversationID: conversationID, messageID: assistantID) { message in
            if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message.content = "已停止。"
            }
        }
    }

    internal func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError || (error as NSError).code == NSUserCancelledError
    }

    internal var shoppingList: [ShoppingListItem] {
        get { shoppingListItems }
        set { shoppingListItems = newValue }
    }

    internal func saveShoppingList() {
        saveShoppingListItems()
    }
}


// --- Merged from ChatViewModel+MultiAgent.swift ---


extension ChatViewModel {
    // MARK: - Multi-Agent logic

    internal struct MultiAgentDraft: Sendable {
        let providerID: String
        let providerName: String
        let model: String
        let content: String
        let error: String?
    }

    internal func completeMultiAgentChat(messages: [Message],
                                         conversationID: UUID,
                                         assistantID: UUID,
                                         primaryProvider: Provider,
                                         primaryModel: String,
                                         primaryAPIKey: String,
                                         originalUserText: String) async throws {
        let candidates = multiAgentCandidateProviders(active: primaryProvider)
        for provider in candidates {
            setChatAgentStep(provider.name, status: .running, detail: provider.id == primaryProvider.id ? primaryModel : economicalModel(for: provider))
        }
        updateChatPlaceholder(
            conversationID: conversationID,
            messageID: assistantID,
            content: "Multi-agent：\(candidates.count) 个 provider 正在并行生成候选草稿，草稿会放在思考面板；稍后由当前 provider 输出 final result…"
        )

        let workerMessages = multiAgentWorkerMessages(from: messages)
        var drafts: [MultiAgentDraft] = []
        await withTaskGroup(of: MultiAgentDraft.self) { group in
            for provider in candidates {
                let model = provider.id == primaryProvider.id ? primaryModel : economicalModel(for: provider)
                let key = apiKey(for: provider)
                group.addTask {
                    await Self.collectMultiAgentDraft(
                        provider: provider,
                        model: model,
                        apiKey: key,
                        messages: workerMessages
                    )
                }
            }

            for await draft in group {
                drafts.append(draft)
                setChatAgentStep(
                    draft.providerName,
                    status: draft.error == nil ? .done : .failed,
                    detail: draft.error ?? "\(draft.model) 已返回候选草稿"
                )
                updateChatReasoning(
                    conversationID: conversationID,
                    messageID: assistantID,
                    content: formatMultiAgentDrafts(drafts.sorted { $0.providerName < $1.providerName })
                )
            }
        }

        let orderedDrafts = drafts.sorted { lhs, rhs in
            if lhs.providerID == primaryProvider.id { return true }
            if rhs.providerID == primaryProvider.id { return false }
            return lhs.providerName < rhs.providerName
        }
        let draftsBlock = formatMultiAgentDrafts(orderedDrafts)
        updateChatReasoning(conversationID: conversationID, messageID: assistantID, content: draftsBlock)
        updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "正在综合最终答案…")
        setChatAgentStep("综合器", status: .running, detail: "\(primaryProvider.name) / \(primaryModel) 正在汇总")

        let synthesisMessages = multiAgentSynthesisMessages(
            baseMessages: messages,
            originalUserText: originalUserText,
            drafts: orderedDrafts
        )
        let service = makeService(apiType: primaryProvider.apiType)
        let stream = try await service.stream(
            messages: synthesisMessages,
            model: primaryModel,
            apiKey: primaryAPIKey,
            baseURL: primaryProvider.baseURL,
            thinkingEnabled: deepThinkingEnabled
        )

        var finalText = ""
        var synthesisReasoning = ""
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .text(let chunk):
                finalText += chunk
                updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: finalText)
            case .reasoning(let chunk):
                synthesisReasoning += chunk
                let combinedReasoning = [
                    draftsBlock,
                    synthesisReasoning.isEmpty ? nil : """
                    ## Final synthesizer thinking
                    \(synthesisReasoning)
                    """
                ].compactMap { $0 }.joined(separator: "\n\n")
                updateChatReasoning(conversationID: conversationID, messageID: assistantID, content: combinedReasoning)
            case .usage(var stats):
                stats.estimatedCostUSD = knownPricing[primaryModel]?.cost(for: stats)
                setUsageForAssistantTurn(conversationID: conversationID, assistantID: assistantID, usage: stats)
            }
        }

        if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateChatPlaceholder(conversationID: conversationID, messageID: assistantID, content: "（没有收到最终汇总）")
            setChatAgentStep("综合器", status: .failed, detail: "没有收到最终汇总")
        } else {
            setChatAgentStep("综合器", status: .done, detail: "最终答案已生成")
        }
    }

    private func multiAgentCandidateProviders(active: Provider) -> [Provider] {
        var result: [Provider] = []
        var seen = Set<String>()
        func append(_ provider: Provider) {
            guard isProviderUsable(provider), !seen.contains(provider.id) else { return }
            seen.insert(provider.id)
            result.append(provider)
        }

        append(active)
        for provider in allProviders where provider.id != active.id {
            append(provider)
        }
        return Array(result.prefix(4))
    }

    func multiAgentPlanDescription(active: Provider) -> String {
        let candidates = multiAgentCandidateProviders(active: active)
        guard candidates.count >= 2 else {
            return "需要至少两个已配置且可用的云端 provider。当前只有 \(candidates.count) 个可用。"
        }
        let names = candidates.map { provider in
            let model = provider.id == active.id
                ? (selectedConversation?.model ?? economicalModel(for: provider))
                : economicalModel(for: provider)
            return "\(provider.name) / \(model)"
        }.joined(separator: "、")
        return "会并行询问 \(candidates.count) 个 provider：\(names)。最后由当前 provider 综合成一个 final result，候选草稿放在思考面板里。"
    }

    private func multiAgentWorkerMessages(from messages: [Message]) -> [Message] {
        let system = messages.first(where: { $0.role == .system })?.content ?? ""
        let nonSystem = messages.filter { $0.role != .system }
        let workerSystem = [
            system,
            """
            你是 multi-agent 模式中的一个独立候选 Agent。请独立解决用户问题，输出你的结论、关键依据、重要不确定性。保持简洁，不要和其他 Agent 协商，也不要写最终汇总。
            """
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        return [Message(role: .system, content: workerSystem)] + nonSystem
    }

    private func multiAgentSynthesisMessages(baseMessages: [Message],
                                             originalUserText: String,
                                             drafts: [MultiAgentDraft]) -> [Message] {
        let baseSystem = baseMessages.first(where: { $0.role == .system })?.content ?? ""
        let system = [
            baseSystem,
            """
            你是 multi-agent orchestrator。你会收到多个 provider 的候选回答。请比较它们，合并最可靠的信息，指出必要的不确定性，最后只输出一个清晰的 final result。不要逐字复述每个候选回答，除非用户需要对比。
            """
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")

        let draftText = drafts.map { draft in
            """
            ### \(draft.providerName) / \(draft.model)
            \(draft.error.map { "Error: \($0)" } ?? draft.content)
            """
        }.joined(separator: "\n\n")
        return [
            Message(role: .system, content: system),
            Message(role: .user, content: """
            用户原始问题：
            \(originalUserText)

            多个 Agent 的候选回答：
            \(draftText)

            请给出最终答案。
            """)
        ]
    }

    private func formatMultiAgentDrafts(_ drafts: [MultiAgentDraft]) -> String {
        guard !drafts.isEmpty else { return "" }
        return """
        ## Multi-agent drafts
        \(drafts.map { draft in
        """
        ### \(draft.providerName) / \(draft.model)
        \(draft.error.map { "Error: \($0)" } ?? draft.content)
        """
        }.joined(separator: "\n\n"))
        """
    }

    nonisolated private static func collectMultiAgentDraft(provider: Provider,
                                                           model: String,
                                                           apiKey: String,
                                                           messages: [Message]) async -> MultiAgentDraft {
        do {
            let service = makeService(apiType: provider.apiType)
            let stream = try await service.stream(
                messages: messages,
                model: model,
                apiKey: apiKey,
                baseURL: provider.baseURL,
                thinkingEnabled: false
            )
            var content = ""
            for try await event in stream {
                try Task.checkCancellation()
                if case .text(let chunk) = event {
                    content += chunk
                }
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return MultiAgentDraft(
                providerID: provider.id,
                providerName: provider.name,
                model: model,
                content: trimmed.isEmpty ? "（空回答）" : String(trimmed.prefix(12_000)),
                error: nil
            )
        } catch {
            return MultiAgentDraft(
                providerID: provider.id,
                providerName: provider.name,
                model: model,
                content: "",
                error: error.localizedDescription
            )
        }
    }
}


// --- Merged from ChatViewModel+Orchestration.swift ---


internal struct ChatToolRunResult {
    var content: String
    var listPayload: ChatListPayload?

    init(_ content: String, listPayload: ChatListPayload? = nil) {
        self.content = content
        self.listPayload = listPayload
    }
}

extension ChatViewModel {
    // MARK: - Tool Orchestration

    internal func confirmChatToolCalls(_ calls: [ToolCall], conversationID: UUID) async -> Bool {
        guard !calls.isEmpty else { return true }
        if let continuation = chatToolConfirmationContinuation {
            continuation.resume(returning: false)
            chatToolConfirmationContinuation = nil
        }

        return await withCheckedContinuation { continuation in
            chatToolConfirmationContinuation = continuation
            pendingChatToolConfirmation = ChatToolConfirmation(
                conversationID: conversationID,
                title: calls.count == 1 ? "允许访问本机工具？" : "允许访问 \(calls.count) 个本机工具？",
                detail: "Chat agent 想访问本机备忘录、提醒事项 or 日历来完成这轮回复。",
                tools: calls.map(chatToolConfirmationItem)
            )
        }
    }

    internal func chatToolRequiresConfirmation(_ call: ToolCall) -> Bool {
        if call.name == "search_apple_notes" || call.name == "create_apple_note" {
            return true
        }
        return false
    }

    internal func skippedChatToolReasons(for calls: [ToolCall]) -> [String: String] {
        let maxToolsPerRound = 6
        let maxSubAgentsPerRound = 3
        var reasons: [String: String] = [:]
        var runnableToolCount = 0
        var subAgentCount = 0

        for call in calls {
            if call.name == "delegate_to_subagent" {
                subAgentCount += 1
                if subAgentCount > maxSubAgentsPerRound {
                    reasons[call.id] = "本轮 Sub-agent 已达到 \(maxSubAgentsPerRound) 个上限，请先综合已有子任务结果。"
                    continue
                }
            }

            runnableToolCount += 1
            if runnableToolCount > maxToolsPerRound {
                reasons[call.id] = "本轮工具调用已达到 \(maxToolsPerRound) 个上限，请先基于已有结果继续。"
            }
        }
        return reasons
    }

    func resolveChatToolConfirmation(approved: Bool) {
        pendingChatToolConfirmation = nil
        
        if scheduleConfirmationContinuation != nil {
            resolveScheduleConfirmation(confirmed: approved)
        }
        
        if let continuation = chatToolConfirmationContinuation {
            chatToolConfirmationContinuation = nil
            continuation.resume(returning: approved)
        }
    }

    private func chatToolConfirmationItem(_ call: ToolCall) -> ChatToolConfirmationItem {
        ChatToolConfirmationItem(
            name: call.name,
            title: chatToolDisplayName(call.name),
            detail: chatToolCallSummary(call)
        )
    }

    private func chatToolDisplayName(_ name: String) -> String {
        switch name {
        case "make_list": return "绘制原生列表"
        case "web_search": return "联网搜索"
        case "web_fetch": return "读取网页"
        case "read_pdf": return "读取 PDF"
        case "search_apple_notes": return "搜索 Apple Notes"
        case "create_apple_note": return "创建 Apple Note"
        case "add_shopping_items": return "添加购物项"
        case "list_shopping_items": return "查看购物清单"
        case "complete_shopping_item": return "完成购物项"
        case "delete_shopping_item": return "删除购物项"
        case "run_skill_script": return "运行 Skill 脚本"
        case "delegate_to_subagent": return "派发 Sub-agent"
        default: return name
        }
    }

    private func chatToolCallSummary(_ call: ToolCall) -> String {
        switch call.name {
        case "make_list":
            return stringArg(call.args, "title") ?? "生成一个原生列表 UI"
        case "web_search":
            return stringArg(call.args, "query") ?? "搜索网页"
        case "web_fetch":
            return stringArg(call.args, "url") ?? "读取网页内容"
        case "read_pdf":
            return stringArg(call.args, "path") ?? "读取本地 PDF"
        case "search_apple_notes":
            return stringArg(call.args, "query") ?? "搜索备忘录"
        case "create_apple_note":
            return stringArg(call.args, "title") ?? "创建备忘录"
        case "add_shopping_items":
            return "添加模型解析出的购物项"
        case "list_shopping_items":
            return boolArg(call.args, "include_done") == true ? "查看全部购物项" : "查看未完成购物项"
        case "complete_shopping_item":
            return stringArg(call.args, "title") ?? stringArg(call.args, "id") ?? "完成购物项"
        case "delete_shopping_item":
            return stringArg(call.args, "title") ?? stringArg(call.args, "id") ?? "删除购物项"
        case "run_skill_script":
            let skill = stringArg(call.args, "skill_name") ?? "Skill"
            let script = stringArg(call.args, "script_path") ?? "脚本"
            return "\(skill) / \(script)"
        case "delegate_to_subagent":
            return ChaoxingTextNormalizer.preview(stringArg(call.args, "task") ?? "子任务", limit: 80)
        default:
            return "工具参数已由模型生成"
        }
    }

    internal var runnableChatSkillScripts: [ChatSkill] {
        chatSkills.filter { $0.isEnabled && !$0.scripts.isEmpty }
    }

    internal var hasRunnableChatSkillScripts: Bool {
        !runnableChatSkillScripts.isEmpty
    }

    internal func shouldUseChatTools(for text: String) -> Bool {
        scheduleModeEnabled ||
        pdfToolEnabled ||
        appleNotesToolEnabled ||
        shoppingListToolEnabled ||
        hasRunnableChatSkillScripts ||
        (webAccessEnabled && shouldUseWebTools(for: text))
    }

    private func shouldUseWebTools(for text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") {
            return true
        }
        let triggers = [
            "联网", "搜索", "搜一下", "查一下", "查找", "最新", "最近", "实时", "当前", "现在",
            "新闻", "官网", "网页", "网址", "url", "price", "today", "latest", "current",
            "search", "browse", "web"
        ]
        return triggers.contains { lower.contains($0) }
    }
}


// --- Merged from ChatViewModel+Providers.swift ---


extension ChatViewModel {
    // MARK: - Providers management
    
    func provider(for id: String) -> Provider {
        allProviders.first { $0.id == id } ?? .openAI
    }

    func apiKey(for provider: Provider) -> String {
        if provider.isBuiltin {
            switch provider.apiType {
            case .openAI:      return openAIKey
            case .anthropic:   return anthropicKey
            case .gemini:      return geminiKey
            case .xiaomiMimo:  return mimoKey
            default:           return ""
            }
        }
        return provider.customAPIKey
    }

    func availableModels(for provider: Provider) -> [String] {
        if provider.apiType == .xiaomiMimo {
            return provider.models.filter { !$0.isEmpty }
        }
        let models = providerModelOverrides[provider.id] ?? provider.models
        return models.filter { !$0.isEmpty }
    }

    func isProviderUsable(_ provider: Provider) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    func economicalModel(for provider: Provider) -> String {
        let known = availableModels(for: provider).compactMap { model -> (String, Double)? in
            guard let pricing = knownPricing[model] else { return nil }
            return (model, pricing.inputPerM + pricing.outputPerM)
        }
        if let cheapest = known.min(by: { $0.1 < $1.1 })?.0 {
            return cheapest
        }
        return availableModels(for: provider).first ?? provider.defaultModel
    }

    func refreshModels(for providerID: String) async throws -> [String] {
        let provider = provider(for: providerID)
        let models = try await fetchProviderModels(provider: provider, apiKey: apiKey(for: provider))
        providerModelOverrides[providerID] = models
        if let index = customProviders.firstIndex(where: { $0.id == providerID }) {
            customProviders[index].models = models
        }
        for index in conversations.indices where conversations[index].providerID == providerID {
            if !models.contains(conversations[index].model), let first = models.first {
                conversations[index].model = first
            }
        }
        saveSettings()
        saveConversations()
        return models
    }

    func addCustomProvider(name: String, baseURL: String, apiKey: String, models: String) {
        let list = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        customProviders.append(Provider(
            id: UUID().uuidString, name: name, apiType: .openAICompatible,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            models: list.isEmpty ? ["default"] : list,
            iconName: "network", colorHex: "6B7280",
            customAPIKey: apiKey
        ))
        saveSettings()
    }

    func updateCustomProvider(_ p: Provider) {
        if let i = customProviders.firstIndex(where: { $0.id == p.id }) {
            customProviders[i] = p; saveSettings()
        }
    }

    func deleteCustomProvider(_ p: Provider) {
        customProviders.removeAll { $0.id == p.id }
        if scheduleAgentProviderID == p.id {
            scheduleAgentProviderID = nil
        }
        for i in conversations.indices where conversations[i].providerID == p.id {
            conversations[i].providerID = "openai"
            conversations[i].model = Provider.openAI.defaultModel
        }
        saveSettings(); saveConversations()
    }

    func updateScheduleAgentProviderSelection(_ selectionID: String) {
        let nextID = selectionID == ChatViewModel.automaticScheduleAgentProviderID ? nil : selectionID
        guard scheduleAgentProviderID != nextID else { return }
        scheduleAgentProviderID = nextID
        saveSettings()
    }
}


// --- Merged from ChatViewModel+Schedule.swift ---

extension ChatViewModel {
    internal func isLegacyImportedCourseEvent(_ event: EKEvent) -> Bool {
        event.notes?.contains(legacyCourseImportMarker) == true
    }

    // MARK: - Permissions

    func refreshRemindersAccess() {
        hasRemindersAccess = remindersService.isAuthorized
    }

    func refreshCalendarAccess() {
        hasCalendarAccess = remindersService.isCalendarAuthorized
    }

    @discardableResult
    func requestRemindersAccess() async -> Bool {
        guard remindersService.needsRemindersRequest else {
            refreshRemindersAccess()
            return hasRemindersAccess
        }
        let granted = await remindersService.requestAccess()
        hasRemindersAccess = granted || remindersService.isAuthorized
        return hasRemindersAccess
    }

    @discardableResult
    func requestCalendarAccess() async -> Bool {
        guard remindersService.needsCalendarRequest else {
            refreshCalendarAccess()
            return hasCalendarAccess
        }
        let granted = await remindersService.requestCalendarAccess()
        hasCalendarAccess = granted || remindersService.isCalendarAuthorized
        return hasCalendarAccess
    }

    // MARK: - Context Management

    func clearScheduleAgentMessages() {
        scheduleMessages.removeAll()
        scheduleContextResetAt = nil
        saveScheduleMessages()
    }

    func resetScheduleAgentContext() {
        let now = Date()
        scheduleContextResetAt = now
        let marker = Message(role: .system, content: "上下文已重置", timestamp: now)
        scheduleMessages.append(marker)
        saveScheduleMessages()
    }

    // MARK: - Quick Capture

    @discardableResult
    func addQuickCapture(text: String, sourceApp: String, capturedAt: Date = Date()) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = QuickCaptureItem(
            sourceApp: sourceApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "剪贴板" : sourceApp,
            capturedAt: capturedAt,
            updatedAt: Date(),
            text: trimmed
        )
        quickCaptures.insert(item, at: 0)
        saveQuickCaptures()
        return item.id
    }

    func offerCompanionClipboard(text: String, sourceApp: String, capturedAt: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionClipboardDismissTask?.cancel()
        companionClipboardOffer = CompanionClipboardOffer(
            sourceApp: sourceApp.isEmpty ? "剪贴板" : sourceApp,
            capturedAt: capturedAt,
            text: String(trimmed.prefix(2_000))
        )
        companionClipboardDismissTask = Task { [weak self, trimmed] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.companionClipboardOffer?.text == trimmed else { return }
                self?.companionClipboardOffer = nil
            }
        }
        if !companionPreferences.isEnabled {
            enableCompanionPet()
        } else {
            CompanionPetWindowManager.shared.show()
        }
    }

    func updateQuickCapture(_ item: QuickCaptureItem) {
        guard let index = quickCaptures.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.updatedAt = Date()
        quickCaptures[index] = updated
        quickCaptures.sort { $0.updatedAt > $1.updatedAt }
        saveQuickCaptures()
    }

    func deleteQuickCapture(_ item: QuickCaptureItem) {
        quickCaptures.removeAll { $0.id == item.id }
        saveQuickCaptures()
    }

    internal func sendQuickCaptureToScheduleAgent(_ item: QuickCaptureItem) {
        guard !isScheduleAgentRunning else {
            scheduleErrorMessage = "日程 Agent 正在处理上一条消息"
            return
        }
        let prompt = quickCapturePrompt(for: item)
        startSendingScheduleAgentMessage(prompt, displayText: quickCaptureDisplayText(for: item))
        if !quickCaptureKeepAfterSend {
            quickCaptures.removeAll { $0.id == item.id }
            saveQuickCaptures()
        }
    }

    private func quickCapturePrompt(for item: QuickCaptureItem) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if quickCaptureIncludeSourceMetadata {
            return """
            快速捕获自聊天 App 的通知。
            来源 App：\(item.sourceApp)
            捕获时间：\(formatter.string(from: item.capturedAt))

            原文：
            \(item.text)

            请解析其中涉及的日程、提醒事项变化。只有原文明确提到具体课程名、调课、停课、补课、换教室、上课安排或课程表查询时，才把它当作课程相关并调用 list_courses；普通考试、截止时间、会议、活动、通知不要查询或展示课程表。若需要创建、修改、完成或删除系统日历/提醒事项，必须生成 App 内确认，等待我确认后再执行。
            """
        }
        return """
        快速捕获的聊天通知：
        \(item.text)

        请解析其中涉及的日程、提醒事项变化。只有原文明确提到具体课程名、调课、停课、补课、换教室、上课安排或课程表查询时，才把它当作课程相关并调用 list_courses；普通考试、截止时间、会议、活动、通知不要查询或展示课程表。若需要创建、修改、完成或删除系统日历/提醒事项，必须生成 App 内确认，等待我确认后再执行。
        """
    }

    private func quickCaptureDisplayText(for item: QuickCaptureItem) -> String {
        let compact = item.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = compact.count > 90 ? String(compact.prefix(90)) + "..." : compact
        return "\(item.sourceApp)：\(preview)"
    }

    private func quickCapturePrompt(for items: [QuickCaptureItem]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let entries = items.enumerated().map { index, item in
            if quickCaptureIncludeSourceMetadata {
                return """
                条目 \(index + 1)
                来源 App：\(item.sourceApp)
                捕获时间：\(formatter.string(from: item.capturedAt))
                原文：
                \(item.text)
                """
            }
            return "条目 \(index + 1)\n原文：\n\(item.text)"
        }.joined(separator: "\n\n---\n\n")

        return """
        快速捕获中转站批量提交。以下内容可能来自多个聊天 App，请合并理解其中涉及的日程、提醒事项变化，按时间顺序处理。

        \(entries)

        只有原文明确提到具体课程名、调课、停课、补课、换教室、上课安排或课程表查询时，才把它当作课程相关并调用 list_courses；普通考试、截止时间、会议、活动、通知不要查询或展示课程表。若需要创建、修改、完成或删除系统日历/提醒事项，必须生成 App 内确认，等待我确认后再执行。课程表是 App 内本地数据，不要导入系统日历。
        """
    }

    private func quickCaptureDisplayText(for items: [QuickCaptureItem]) -> String {
        if items.count == 1, let first = items.first { return quickCaptureDisplayText(for: first) }
        let sources = Array(Set(items.map(\.sourceApp))).sorted().joined(separator: "、")
        return "中转站批量提交 \(items.count) 条\(sources.isEmpty ? "" : " · \(sources)")"
    }

    // MARK: - Task Management

    func startSendingScheduleAgentMessage(_ text: String, displayText: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, scheduleTask == nil, !isScheduleAgentRunning else { return }
        let taskID = UUID()
        scheduleTaskID = taskID
        scheduleTask = Task { await sendScheduleAgentMessage(text, displayText: displayText, taskID: taskID) }
    }

    func cancelScheduleAgentResponse() {
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleTaskID = nil
        isScheduleAgentRunning = false
        scheduleErrorMessage = nil
        pendingScheduleConfirmation = nil
        if let continuation = scheduleConfirmationContinuation {
            scheduleConfirmationContinuation = nil
            continuation.resume(returning: false)
        }
    }

    // MARK: - Sidebar & Sync

    func refreshScheduleSidebar() async {
        scheduleRefreshSequence += 1
        let refreshID = scheduleRefreshSequence
        refreshRemindersAccess()
        refreshCalendarAccess()
        isScheduleSidebarLoading = true
        defer {
            if refreshID == scheduleRefreshSequence {
                isScheduleSidebarLoading = false
                scheduleSidebarLastUpdated = Date()
            }
        }
        var snapshot = scheduleSidebar
        let now = Date()
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now.addingTimeInterval(14 * 24 * 60 * 60)
        let week = currentWeekInterval()
        var upcomingEvents: [ScheduleCalendarEventItem] = scheduleSidebar.events
        var activeReminders: [ScheduleReminderItem] = scheduleSidebar.reminders
        var assignmentItems: [ScheduleChaoxingAssignmentItem] = scheduleSidebar.chaoxingAssignments

        snapshot.courses = Array(courseSchedule.filter { $0.endDate >= now && $0.startDate <= rangeEnd }.sorted { $0.startDate < $1.startDate }.prefix(24))
        if hasCalendarAccess {
            let events = remindersService.getEvents(startDate: now, endDate: rangeEnd).sorted { $0.startDate < $1.startDate }
            let weekEvents = remindersService.getEvents(startDate: week.start, endDate: week.end).filter { !isLegacyImportedCourseEvent($0) }.sorted { $0.startDate < $1.startDate }
            cachedAgentEvents = events
            snapshot.events = Array(events.filter { !isLegacyImportedCourseEvent($0) }.prefix(10).map(RemindersService.snapshot))
            snapshot.weekEvents = weekEvents.map(RemindersService.snapshot)
            upcomingEvents = events.filter { !isLegacyImportedCourseEvent($0) }.map(RemindersService.snapshot)
        }
        if hasRemindersAccess {
            let reminders = await remindersService.getReminders(includeCompleted: false)
            let sorted = reminders.filter { !$0.isCompleted }.sorted(by: agentCompareReminders)
            cachedAgentReminders = sorted
            activeReminders = sorted.map(RemindersService.snapshot)
            snapshot.reminders = Array(activeReminders.prefix(10))
        }
        if ChaoxingService.shared.isLoggedIn {
            do {
                let assignments = try await ChaoxingService.shared.fetchAllPendingAssignments()
                assignmentItems = visibleChaoxingAssignmentItems(assignments, now: now)
                snapshot.chaoxingAssignments = Array(assignmentItems.prefix(10))
                await refreshChaoxingMessagesForSidebar(assignments: assignmentItems)
            } catch {
                assignmentItems = snapshot.chaoxingAssignments
                chaoxingRuntimeSyncStatus.lastError = error.localizedDescription
                saveChaoxingRuntimeState()
            }
            snapshot.chaoxingMessageInsights = []
        }
        guard refreshID == scheduleRefreshSequence else { return }
        scheduleSidebar = snapshot
        refreshTodayWidget(assignments: assignmentItems, reminders: activeReminders, events: upcomingEvents, now: now)
    }

    private func refreshChaoxingMessagesForSidebar(assignments: [ScheduleChaoxingAssignmentItem]) async {
        guard ChaoxingService.shared.isLoggedIn, chaoxingMessageExtractionTask == nil else { return }
        guard let messages = try? await ChaoxingService.shared.fetchRecentMessages(maxConversations: 12, perConversation: 20) else { return }
        chaoxingMessageExtractionTask = Task { [weak self] in
            await self?.extractImportantChaoxingMessages(from: messages, assignments: assignments)
        }
    }

    func startChaoxingRuntimeSyncLoop() {
        chaoxingRuntimeSyncTask?.cancel()
        chaoxingRuntimeSyncStatus.isRunning = true
        chaoxingRuntimeSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.runChaoxingRuntimeSyncPass()
                let nanos = UInt64(max(20, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    @discardableResult
    func runChaoxingRuntimeSyncPass(forceFullFetch: Bool = false) async -> TimeInterval {
        guard ChaoxingService.shared.isLoggedIn else {
            chaoxingRuntimeSyncStatus.isRefreshing = false
            chaoxingRuntimeSyncStatus.nextRefreshAt = Date().addingTimeInterval(300)
            saveChaoxingRuntimeState()
            return 300
        }
        guard !chaoxingRuntimeSyncStatus.isRefreshing, !isChaoxingMessageExtractionRunning else { return 60 }
        let now = Date()
        chaoxingRuntimeSyncStatus.isRefreshing = true
        chaoxingRuntimeSyncStatus.lastProbeAt = now
        chaoxingRuntimeSyncStatus.lastError = nil
        refreshCompanionState(reason: "sync-start")
        do {
            let probes = try await ChaoxingService.shared.fetchMessageConversationProbes(limit: 12)
            let changed = probes.filter { chaoxingProbeSignatures[$0.id] != $0.signature }
            for probe in probes { chaoxingProbeSignatures[probe.id] = probe.signature }
            let importantWindow = chaoxingImportantRuntimeWindow(now: now)
            let dueFullFetch = forceFullFetch || shouldRunPeriodicChaoxingFullFetch(now: now, importantWindow: importantWindow)
            if !changed.isEmpty || dueFullFetch {
                let conversationIDs = dueFullFetch ? Set(probes.map(\.id)) : Set(changed.map(\.id))
                let messages = try await ChaoxingService.shared.fetchRecentMessages(forConversationIDs: conversationIDs, perConversation: importantWindow ? 20 : 12)
                await runChaoxingMemoryPipelineFromRuntime(messages: messages, now: now)
                chaoxingRuntimeSyncStatus.lastFullFetchAt = now
                chaoxingRuntimeSyncStatus.lastSuccessfulFetchAt = now
                chaoxingRuntimeSyncStatus.consecutiveNoChangeCount = 0
            } else {
                chaoxingRuntimeSyncStatus.consecutiveNoChangeCount += 1
            }
            chaoxingRuntimeSyncStatus.isRefreshing = false
            let next = nextChaoxingRuntimeInterval(now: now)
            chaoxingRuntimeSyncStatus.nextRefreshAt = now.addingTimeInterval(next)
            saveChaoxingRuntimeState()
            refreshCompanionState(reason: "sync-finish")
            return next
        } catch {
            chaoxingRuntimeSyncStatus.isRefreshing = false
            chaoxingRuntimeSyncStatus.lastError = error.localizedDescription
            chaoxingRuntimeSyncStatus.consecutiveNoChangeCount += 1
            let next: TimeInterval = min(600, 120 + TimeInterval(chaoxingRuntimeSyncStatus.consecutiveNoChangeCount * 60))
            chaoxingRuntimeSyncStatus.nextRefreshAt = now.addingTimeInterval(next)
            saveChaoxingRuntimeState()
            refreshCompanionState(reason: "sync-error")
            return next
        }
    }

    private func runChaoxingMemoryPipelineFromRuntime(messages: [ChaoxingMessage], now: Date) async {
        guard !messages.isEmpty else { return }
        let assignments = (try? await ChaoxingService.shared.fetchAllPendingAssignments()) ?? []
        let assignmentItems = visibleChaoxingAssignmentItems(assignments, now: now)
        let provider = activeAgentProvider
        let result = await ChaoxingMemoryAgent(store: chaoxingMemoryStore).process(messages: messages, assignments: assignmentItems, courses: courseSchedule, mutedConversationNames: chaoxingMutedConversationNames, provider: provider, model: economicalModel(for: provider), apiKey: apiKey(for: provider), now: now)
        processedChaoxingMessageIDs.formUnion(result.syncState.processedSourceIDs)
        saveChaoxingMessageState()
        chaoxingMessageInsights = Array(result.insights.prefix(40))
        scheduleSidebar.chaoxingMessageInsights = []
        refreshTodayWidgetFromCachedSidebar()
    }

    private func chaoxingImportantRuntimeWindow(now: Date) -> Bool {
        if let until = chaoxingRuntimeSyncStatus.activeImportanceWindowUntil, until > now { return true }
        if !todayWidget.memoryHighlights.isEmpty { return true }
        if scheduleSidebar.chaoxingAssignments.contains(where: { $0.dueDate.timeIntervalSince(now) <= 24 * 60 * 60 }) { return true }
        if courseSchedule.contains(where: { $0.startDate >= now && $0.startDate.timeIntervalSince(now) <= 2 * 60 * 60 }) { return true }
        return false
    }

    private func shouldRunPeriodicChaoxingFullFetch(now: Date, importantWindow: Bool) -> Bool {
        guard let last = chaoxingRuntimeSyncStatus.lastFullFetchAt else { return true }
        let maxAge: TimeInterval = importantWindow ? 10 * 60 : 25 * 60
        return now.timeIntervalSince(last) >= maxAge
    }

    private func nextChaoxingRuntimeInterval(now: Date) -> TimeInterval {
        if chaoxingImportantRuntimeWindow(now: now) { return 45 }
        let noChange = chaoxingRuntimeSyncStatus.consecutiveNoChangeCount
        if noChange <= 2 { return 90 }
        if noChange <= 5 { return 240 }
        return 600
    }

    private func extractImportantChaoxingMessages(from messages: [ChaoxingMessage], assignments: [ScheduleChaoxingAssignmentItem]) async {
        guard !messages.isEmpty else { chaoxingMessageExtractionTask = nil; return }
        let provider = activeAgentProvider
        let key = apiKey(for: provider)
        isChaoxingMessageExtractionRunning = true
        defer {
            isChaoxingMessageExtractionRunning = false
            chaoxingMessageExtractionTask = nil
        }
        let now = Date()
        let result = await ChaoxingMemoryAgent(store: chaoxingMemoryStore).process(messages: messages, assignments: assignments, courses: courseSchedule, mutedConversationNames: chaoxingMutedConversationNames, provider: provider, model: economicalModel(for: provider), apiKey: key, now: now)
        processedChaoxingMessageIDs.formUnion(result.syncState.processedSourceIDs)
        saveChaoxingMessageState()
        chaoxingMessageInsights = Array(result.insights.prefix(40))
        scheduleSidebar.chaoxingMessageInsights = []
        refreshTodayWidgetFromCachedSidebar()
    }

    func refreshChaoxingInsightsFromMemory(now: Date = Date()) {
        let memory = chaoxingMemoryStore.readMemory(now: now)
        chaoxingMessageInsights = ChaoxingMemoryReducer.insights(from: memory, now: now, limit: 40)
        scheduleSidebar.chaoxingMessageInsights = []
        refreshTodayWidgetFromCachedSidebar()
    }

    // MARK: - Visibility & Logic

    private func visibleChaoxingAssignmentItems(_ assignments: [ChaoxingAssignment], now: Date = Date()) -> [ScheduleChaoxingAssignmentItem] {
        assignments.compactMap { scheduleChaoxingAssignmentItem(from: $0, now: now) }.sorted { $0.dueDate < $1.dueDate }
    }

    private func scheduleChaoxingAssignmentItem(from assignment: ChaoxingAssignment, now: Date = Date()) -> ScheduleChaoxingAssignmentItem? {
        guard let dueDate = assignment.dueDate, dueDate > now else { return nil }
        guard isUnfinishedChaoxingAssignment(assignment) else { return nil }
        return ScheduleChaoxingAssignmentItem(id: "\(assignment.courseId)-\(assignment.id)", originalID: assignment.id, courseID: assignment.courseId, courseName: assignment.courseName, title: assignment.title, dueDate: dueDate, status: assignment.status, type: assignment.type, remainingTime: assignment.remainingTime)
    }

    private func isUnfinishedChaoxingAssignment(_ assignment: ChaoxingAssignment) -> Bool {
        let status = assignment.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.isEmpty || status == "0" || status.contains("未") || status.contains("待完成") || status.contains("待提交") { return true }
        if status == "1" { return false }
        let completedMarkers = ["已提交", "已完成", "已做", "待批阅", "已批阅", "批阅中", "提交成功", "已截止"]
        return !completedMarkers.contains { status.contains($0) }
    }

    func isImportantReminder(_ reminder: ScheduleReminderItem) -> Bool { importantScheduleItemIDs.contains(importanceKey(kind: "reminder", id: reminder.id)) }
    func isImportantEvent(_ event: ScheduleCalendarEventItem) -> Bool { importantScheduleItemIDs.contains(importanceKey(kind: "event", id: event.id)) }
    func toggleReminderImportance(_ reminder: ScheduleReminderItem) { toggleImportance(kind: "reminder", id: reminder.id) }
    func toggleEventImportance(_ event: ScheduleCalendarEventItem) { toggleImportance(kind: "event", id: event.id) }

    private func toggleImportance(kind: String, id: String) {
        let key = importanceKey(kind: kind, id: id)
        if importantScheduleItemIDs.contains(key) { importantScheduleItemIDs.remove(key) } else { importantScheduleItemIDs.insert(key) }
        saveImportantScheduleItems()
        refreshTodayWidgetFromCachedSidebar()
    }

    private func importanceKey(kind: String, id: String) -> String { "\(kind):\(id)" }

    // MARK: - Today Widget Refresh

    func refreshTodayWidgetFromCachedSidebar() {
        let cachedEvents = cachedAgentEvents.filter { !isLegacyImportedCourseEvent($0) }.sorted { $0.startDate < $1.startDate }.map(RemindersService.snapshot)
        let cachedReminders = cachedAgentReminders.filter { !$0.isCompleted }.sorted(by: agentCompareReminders).map(RemindersService.snapshot)
        refreshTodayWidget(assignments: scheduleSidebar.chaoxingAssignments, reminders: cachedReminders.isEmpty ? scheduleSidebar.reminders : cachedReminders, events: cachedEvents.isEmpty ? scheduleSidebar.events : cachedEvents, now: Date())
    }

    func refreshTodayWidget(assignments: [ScheduleChaoxingAssignmentItem], reminders: [ScheduleReminderItem], events: [ScheduleCalendarEventItem], now: Date) {
        let today = dayInterval(containing: now)
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now.addingTimeInterval(14 * 24 * 60 * 60)
        let upcomingCourses = courseSchedule.filter { $0.endDate >= now && $0.startDate <= rangeEnd }.sorted { $0.startDate < $1.startDate }
        let todayCourses = courseSchedule.filter { $0.endDate >= now && eventIntersects($0, today) }.sorted { $0.startDate < $1.startDate }
        let todayAssignments = assignments.filter { $0.dueDate >= now && today.contains($0.dueDate) }.sorted { $0.dueDate < $1.dueDate }
        let dueReminders = reminders.filter { r in r.dueDate.map { $0 >= now && today.contains($0) } ?? false }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let todayEvents = events.filter { $0.endDate >= now && eventIntersects($0, today) }
        let importantReminders = dueReminders.filter(isImportantReminder)
        let importantEvents = todayEvents.filter(isImportantEvent)
        let memoryHighlights = todayMemoryHighlights(now: now).filter { !isItemSemanticallyExpired($0, now: now) }
        let courseWarnings = courseMemoryWarningInsights(now: now).filter { !isItemSemanticallyExpired($0, now: now) }
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        let upcomingEvents7 = events.filter { $0.endDate >= now && $0.startDate >= tomorrow && $0.startDate <= weekEnd }.sorted { $0.startDate < $1.startDate }
        let upcomingReminders7 = reminders.filter { r in r.dueDate.map { $0 >= tomorrow && $0 <= weekEnd } ?? false }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let attentionItems = buildTodayAttentionItems(assignments: assignments, reminders: reminders, events: events, courses: upcomingCourses, memoryHighlights: memoryHighlights, courseWarnings: courseWarnings, now: now)

        let source = TodayWidgetSummarySource(attentionItems: attentionItems, todayAssignments: todayAssignments, importantReminders: importantReminders, importantEvents: importantEvents, todayDueReminders: dueReminders, todayEvents: todayEvents, todayCourses: todayCourses, allAssignments: assignments, allActiveReminders: reminders, allUpcomingEvents: events, allUpcomingCourses: upcomingCourses, memoryHighlights: memoryHighlights, courseWarnings: courseWarnings, quickCaptures: Array(quickCaptures.prefix(20)), recentConversationMessages: [], recentScheduleMessages: [])
        let nextHash = hashTodayWidgetSource(source)
        let oldSummary = todayWidget.sourceHash == nextHash ? todayWidget.summary : "未生成"
        let oldGeneratedAt = todayWidget.sourceHash == nextHash ? todayWidget.generatedAt : nil

        todayWidget = TodayWidgetSnapshot(summary: oldSummary, sourceHash: nextHash, generatedAt: oldGeneratedAt, attentionItems: Array(attentionItems.prefix(8)), assignments: Array(todayAssignments.prefix(6)), importantReminders: Array(importantReminders.prefix(5)), importantEvents: Array(importantEvents.prefix(5)), memoryHighlights: Array(memoryHighlights.prefix(5)), upcomingEvents: Array(upcomingEvents7.prefix(5)), upcomingReminders: Array(upcomingReminders7.prefix(5)))
        saveTodayWidgetSnapshot()
        refreshCompanionState(reason: "today")
        guard oldGeneratedAt == nil else { return }
        regenerateTodayWidgetSummary(source: source, sourceHash: nextHash)
    }

    private func regenerateTodayWidgetSummary(source: TodayWidgetSummarySource, sourceHash: String) {
        todayWidgetSummaryTask?.cancel()
        todayWidgetSummaryTask = Task {
            isTodayWidgetSummaryRunning = true
            defer { isTodayWidgetSummaryRunning = false }
            let provider = activeAgentProvider
            let key = apiKey(for: provider)
            guard !key.isEmpty else {
                todayWidget.summary = "未生成"
                todayWidget.generatedAt = nil
                saveTodayWidgetSnapshot()
                return
            }
            do {
                let response = try await agentComplete(messages: [AgentMsg(role: .system, content: "你是一个极简日程助理。请基于结构化注意力清单，总结未来约 48 小时最值得关注的事务，不超过 120 字。越近越重要：逾期/今天最高，明天次之，后天只在重要时提。用户的日历事件和提醒事项拥有高优先级，学习通 DDL、调课、考试也很重要。普通上课/课程表仅作最低优先级背景，除非涉及调课、停课、补课、换教室、改时间或考试，不要把普通上课写进摘要。不得凭空新增事项。重要规则：1. 标题含“（班）”或“(班)”表示调休补班/工作日标记，不表示今天是该节日。2. 任何现在已经结束的事件、考试、课程、会议都不要写进摘要；只有未完成且仍需补救的逾期任务可以提。3. 对于语义重点（Insight），如果其文本提到的具体时间点已经过去（例如现在 14:30，文本提到 12:00 截止），除非是重要的逾期未完成任务，否则应视作已完成或已失效，不要在总结中提及。4. 不要列清单，不要 Markdown，不要寒暄。"), AgentMsg(role: .user, content: todayWidgetSummaryPrompt(source))], tools: [], provider: provider, model: economicalModel(for: provider), apiKey: key)
                let summary = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                guard !Task.isCancelled, todayWidget.sourceHash == sourceHash else { return }
                todayWidget.summary = summary.isEmpty ? "未生成" : summary
                todayWidget.generatedAt = summary.isEmpty ? nil : Date()
                saveTodayWidgetSnapshot()
                refreshCompanionState(reason: "today-summary")
            } catch {
                guard !Task.isCancelled, todayWidget.sourceHash == sourceHash else { return }
                todayWidget.summary = "未生成"
                todayWidget.generatedAt = nil
                saveTodayWidgetSnapshot()
                refreshCompanionState(reason: "today-summary-fallback")
            }
        }
    }

    // MARK: - Attention Logic

    private func buildTodayAttentionItems(assignments: [ScheduleChaoxingAssignmentItem], reminders: [ScheduleReminderItem], events: [ScheduleCalendarEventItem], courses: [ScheduleCalendarEventItem], memoryHighlights: [ScheduleChaoxingMessageInsightItem], courseWarnings: [ScheduleChaoxingMessageInsightItem], now: Date) -> [TodayAttentionItem] {
        let horizonEnd = now.addingTimeInterval(48 * 60 * 60)
        let backgroundEnd = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        var items: [TodayAttentionItem] = []
        items += assignments.filter { $0.dueDate >= now && $0.dueDate <= backgroundEnd }.map { TodayAttentionItem(id: "assignment:\($0.id)", kind: "assignment", title: $0.title, detail: "\($0.courseName) · 截止 \(formatRelativeScheduleDate($0.dueDate, now: now))", date: $0.dueDate, score: todayAttentionScore(date: $0.dueDate, now: now, sourceWeight: 24, keywordText: $0.title + $0.courseName), horizon: $0.dueDate <= horizonEnd ? "upcoming" : "background") }
        items += reminders.filter { !$0.isCompleted }.compactMap { r -> TodayAttentionItem? in
            guard let due = r.dueDate, due <= backgroundEnd else { return nil }
            let marked = isImportantReminder(r) ? 25.0 : 0.0
            return TodayAttentionItem(id: "reminder:\(r.id)", kind: "reminder", title: r.title, detail: "提醒事项 · \(formatRelativeScheduleDate(due, now: now))", date: due, score: todayAttentionScore(date: due, now: now, sourceWeight: 22 + marked, keywordText: [r.title, r.notes ?? ""].joined(separator: " ")), horizon: due <= now ? "primary" : (due <= horizonEnd ? "upcoming" : "background"))
        }
        items += events.filter { $0.endDate >= now && $0.startDate <= backgroundEnd }.map { e in
            let marked = isImportantEvent(e) ? 25.0 : 0.0
            return TodayAttentionItem(id: "event:\(e.id)", kind: "event", title: e.title, detail: "日历 · \(formatRelativeScheduleDate(e.startDate, now: now))", date: e.startDate, score: todayAttentionScore(date: e.startDate, now: now, sourceWeight: 20 + marked, keywordText: [e.title, e.notes ?? "", e.location ?? ""].joined(separator: " ")), horizon: eventIntersects(e, dayInterval(containing: now)) ? "primary" : (e.startDate <= horizonEnd ? "upcoming" : "background"))
        }
        items += courses.filter { $0.endDate >= now && $0.startDate <= backgroundEnd }.map { course in
            let text = [course.title, course.notes ?? "", course.location ?? ""].joined(separator: " ")
            let isChange = isCourseChangeAttention(text)
            let horizon = isChange
                ? (eventIntersects(course, dayInterval(containing: now)) ? "primary" : (course.startDate <= horizonEnd ? "upcoming" : "background"))
                : "background"
            let score = isChange
                ? todayAttentionScore(date: course.startDate, now: now, sourceWeight: 34, keywordText: text)
                : todayAttentionScore(date: course.startDate, now: now, sourceWeight: -45, keywordText: "")
            return TodayAttentionItem(id: "course:\(course.id)", kind: "course", title: course.title, detail: "课程 · \(formatRelativeScheduleDate(course.startDate, now: now))", date: course.startDate, score: score, horizon: horizon)
        }
        items += (memoryHighlights + courseWarnings).filter { !isItemSemanticallyExpired($0, now: now) }.prefix(10).map { i in
            let importance = i.importance == "high" ? 38.0 : 24.0
            return TodayAttentionItem(id: "memory:\(i.id)", kind: "memory", title: i.title, detail: i.actionHint ?? i.summary, date: nil, score: importance + todayKeywordBoost([i.title, i.summary, i.actionHint ?? ""].joined(separator: " ")), horizon: i.importance == "high" ? "primary" : "upcoming")
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.sorted {
            if $0.horizon != $1.horizon { return horizonRank($0.horizon) < horizonRank($1.horizon) }
            if abs($0.score - $1.score) > 0.1 { return $0.score > $1.score }
            return ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        }
    }

    private func isItemSemanticallyExpired(_ item: ScheduleChaoxingMessageInsightItem, now: Date) -> Bool {
        let text = "\(item.title) \(item.summary) \(item.actionHint ?? "")"
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,2})[:：](\\d{2})|(\\d{1,2})[点]") else { return false }
        let ns = text as NSString
        let results = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for result in results {
            var h = 0, m = 0
            if result.range(at: 1).location != NSNotFound { h = Int(ns.substring(with: result.range(at: 1))) ?? 0; m = Int(ns.substring(with: result.range(at: 2))) ?? 0 }
            else if result.range(at: 3).location != NSNotFound { h = Int(ns.substring(with: result.range(at: 3))) ?? 0 }
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
            comps.hour = h; comps.minute = m
            if let target = Calendar.current.date(from: comps), target < now.addingTimeInterval(-45 * 60) { return true }
        }
        return false
    }

    private func horizonRank(_ h: String) -> Int { h == "primary" ? 0 : (h == "upcoming" ? 1 : 2) }
    private func todayAttentionScore(date: Date, now: Date, sourceWeight: Double, keywordText: String) -> Double {
        let hours = date.timeIntervalSince(now) / 3600
        let urgency: Double
        switch hours { case ..<0: urgency = 100; case 0..<6: urgency = 90; case 6..<24: urgency = 75; case 24..<48: urgency = 45; case 48..<72: urgency = 20; default: urgency = 5 }
        return urgency + sourceWeight + todayKeywordBoost(keywordText)
    }
    private func todayKeywordBoost(_ text: String) -> Double { ["考试", "期中", "期末", "答辩", "截止", "ddl", "DDL", "提交", "确认", "调课", "停课", "补课", "换教室", "会议"].contains { text.localizedCaseInsensitiveContains($0) } ? 18 : 0 }
    private func isCourseChangeAttention(_ text: String) -> Bool { ["调课", "停课", "补课", "换教室", "换地点", "改教室", "改地点", "改时间", "课程变更"].contains { text.localizedCaseInsensitiveContains($0) } }
    private func formatRelativeScheduleDate(_ date: Date, now: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天 \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))" }
        if Calendar.current.isDateInTomorrow(date) { return "明天 \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))" }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "zh_CN"); fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Prompt Formatting

    private func todayWidgetSummaryPrompt(_ source: TodayWidgetSummarySource) -> String {
        var sections: [String] = []
        sections.append("注意力清单（已按48小时衰减排序）：\n" + (source.attentionItems.isEmpty ? "无" : source.attentionItems.prefix(10).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("现在/今天最该注意：\n" + (source.attentionItems.filter { $0.horizon == "primary" }.prefix(5).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("未来48小时：\n" + (source.attentionItems.filter { $0.horizon == "upcoming" }.prefix(6).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("今日课程：\n" + (source.todayCourses.isEmpty ? "无" : source.todayCourses.map(formatEventForTodayWidget).joined(separator: "\n")))
        sections.append("今日日历事件：\n" + (source.todayEvents.isEmpty ? "无" : source.todayEvents.map(formatEventForTodayWidget).joined(separator: "\n")))
        sections.append("学习通 memory 重点：\n" + (source.memoryHighlights.isEmpty ? "无" : source.memoryHighlights.map(formatMemoryInsightForTodayWidget).joined(separator: "\n")))
        return "当前时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))。请浓缩今日事务，48小时内优先。已经结束的考试/课程/会议不要写入摘要。普通上课只作最低优先级背景；不要把普通课程写入摘要，除非它涉及调课、停课、补课、换教室、改时间、考试或其他变化。\n\n" + sections.joined(separator: "\n\n")
    }

    private func hashTodayWidgetSource(_ source: TodayWidgetSummarySource) -> String {
        guard let data = try? JSONEncoder().encode(source) else { return UUID().uuidString }
        var versioned = Data("today-widget-v7-expired-memory-filter\n".utf8); versioned.append(data)
        return SHA256.hash(data: versioned).map { String(format: "%02x", $0) }.joined()
    }

    private func dayInterval(containing date: Date) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24*3600))
    }

    private func eventIntersects(_ event: ScheduleCalendarEventItem, _ interval: DateInterval) -> Bool { DateInterval(start: event.startDate, end: max(event.endDate, event.startDate.addingTimeInterval(60))).intersects(interval) }
    private func formatChaoxingAssignmentForTodayWidget(_ a: ScheduleChaoxingAssignmentItem) -> String { "• [\(a.courseName)] \(a.title)，截止 \(formatShortDateTime(a.dueDate))" }
    private func formatAttentionItemForTodayWidget(_ i: TodayAttentionItem) -> String { "• [\(i.horizon)] \(i.title)，\(i.detail)，\(i.date.map(formatShortDateTime) ?? "")" }
    private func formatReminderForTodayWidget(_ r: ScheduleReminderItem) -> String { "• \(r.title)，截止 \(r.dueDate.map(formatShortDateTime) ?? "")" }
    private func formatEventForTodayWidget(_ e: ScheduleCalendarEventItem) -> String { "• \(e.title)，\(e.isAllDay ? "全天" : formatShortDateTime(e.startDate))" }
    private func formatMemoryInsightForTodayWidget(_ i: ScheduleChaoxingMessageInsightItem) -> String { "• \(i.title): \(i.summary)" }

    // MARK: - Memory Integration

    private func todayMemoryHighlights(now: Date) -> [ScheduleChaoxingMessageInsightItem] {
        let memory = chaoxingMemoryStore.readMemory(now: now)
        let entries = memory.entries.filter { $0.expiresAt > now && ($0.importance == "high" || $0.importance == "medium") }
        return Array(ChaoxingMemoryReducer.insights(from: ChaoxingMemoryDocument(schemaVersion: memory.schemaVersion, updatedAt: memory.updatedAt, entries: entries), now: now, limit: 8))
    }

    private func courseMemoryWarningInsights(now: Date) -> [ScheduleChaoxingMessageInsightItem] {
        let memory = chaoxingMemoryStore.readMemory(now: now)
        let entries = memory.entries.filter { $0.expiresAt > now && isCourseWarningMemory($0) }
        return Array(ChaoxingMemoryReducer.insights(from: ChaoxingMemoryDocument(schemaVersion: memory.schemaVersion, updatedAt: memory.updatedAt, entries: entries), now: now, limit: 8))
    }

    func courseMemoryAnnotations(for event: ScheduleCalendarEventItem, now: Date = Date()) -> [CourseMemoryAnnotation] {
        let memory = chaoxingMemoryStore.readMemory(now: now)
        return memory.entries.filter { $0.expiresAt > now && isCourseWarningMemory($0) && memoryEntry($0, matchesCourseEvent: event) }.sorted(by: ChaoxingMemoryReducer.sortEntries).prefix(2).map { CourseMemoryAnnotation(id: $0.id, title: $0.title, detail: compactTextForTodayWidget($0.summary, limit: 120), actionHint: $0.actionHint.map { compactTextForTodayWidget($0, limit: 100) }, importance: $0.importance) }
    }

    private func isActionableMemoryCategory(_ c: String) -> Bool { ["course_change", "exam", "assignment_note", "event", "deadline", "notice"].contains(c) }
    private func isCourseWarningMemory(_ e: ChaoxingMemoryEntry) -> Bool { e.category == "course_change" || e.category == "exam" || ["调课", "停课", "补课", "换教室"].contains { [e.title, e.summary].joined().contains($0) } }
    private func memoryEntry(_ entry: ChaoxingMemoryEntry, matchesCourseEvent event: ScheduleCalendarEventItem) -> Bool {
        let eventKey = ChaoxingTextNormalizer.keyText(event.title)
        guard !eventKey.isEmpty else { return false }
        let textKey = ChaoxingTextNormalizer.keyText([entry.title, entry.summary, entry.actionHint ?? "", entry.linkedCourseKey ?? ""].joined())
        return textKey.contains(eventKey)
    }

    private func formatQuickCaptureForTodayWidget(_ item: QuickCaptureItem) -> String { "• \(item.sourceApp): \(compactTextForTodayWidget(item.text, limit: 140))" }
    private func compactTextForTodayWidget(_ t: String, limit: Int) -> String {
        let compact = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count > limit ? String(compact.prefix(limit)) + "..." : compact
    }

    private func formatShortDateTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short; f.timeStyle = .short
        return f.string(from: d)
    }

    private func currentWeekInterval() -> DateInterval {
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 7, to: start)!)
    }

    // MARK: - Core Execution

    func sendScheduleAgentMessage(_ text: String, displayText: String? = nil, taskID: UUID? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isScheduleAgentRunning else { finishScheduleTask(taskID); return }
        defer { finishScheduleTask(taskID) }
        refreshRemindersAccess(); refreshCalendarAccess()
        let provider = activeAgentProvider, key = apiKey(for: provider)
        guard !key.isEmpty else { scheduleErrorMessage = "请配置 API Key"; return }
        let model = economicalModel(for: provider)
        scheduleMessages.append(Message(role: .user, content: displayText ?? trimmed))
        let placeholder = Message(role: .assistant, content: "")
        scheduleMessages.append(placeholder); isScheduleAgentRunning = true; saveScheduleMessages()
        let now = Date()
        let dynamicContext = harness.buildDynamicContextPrompt(now: now) + "\n\n" + harness.makeTurnContextPrompt(now: now, cachedReminders: cachedAgentReminders, cachedEvents: cachedAgentEvents, hasRemindersAccess: hasRemindersAccess, hasCalendarAccess: hasCalendarAccess, courseSchedule: courseSchedule, importantChaoxingMessages: chaoxingMessageInsights, isLegacyImportedCourse: { [weak self] in self?.isLegacyImportedCourseEvent($0) ?? false })
        var agentMessages = harness.buildMessages(staticSystemContent: harness.buildStaticSystemPrompt(customSchedulePrompt: scheduleAgentPrompt), dynamicContext: dynamicContext, scheduleMessages: scheduleMessages, excluding: placeholder.id, contextResetAt: scheduleContextResetAt)
        if let lastUser = agentMessages.lastIndex(where: { $0.role == .user }) { agentMessages[lastUser].content = trimmed }
        do {
            let result = try await scheduleOrchestrator.run(ScheduleAgentRunRequest(userText: trimmed, displayText: displayText, placeholderID: placeholder.id, messages: agentMessages, context: buildSkillContext(now: now), provider: provider, model: model, apiKey: key, thinkingBudget: agentThinkingBudgetTokens), callbacks: ScheduleAgentCallbacks(progress: { [weak self] in self?.updateSchedulePlaceholder(placeholder.id, $0) }, payload: { [weak self] in self?.updateSchedulePayload(placeholder.id, $0) }, reasoning: { [weak self] in self?.updateScheduleReasoning(placeholder.id, $0) }))
            updateSchedulePlaceholder(placeholder.id, result.finalText)
        } catch { updateSchedulePlaceholder(placeholder.id, "**Error:** \(error.localizedDescription)") }
        saveScheduleMessages(); if !Task.isCancelled { await refreshScheduleSidebar() }
    }

    func buildSkillContext(now: Date = Date(), conversationID: UUID? = nil) -> SkillContext {
        SkillContext(remindersService: remindersService, hasRemindersAccess: hasRemindersAccess, hasCalendarAccess: hasCalendarAccess, isLegacyImportedCourse: { [weak self] in self?.isLegacyImportedCourseEvent($0) ?? false }, confirmMutation: { [weak self] k, es, cs in await self?.confirmScheduleMutation(kind: k, entitySummary: es, changesSummary: cs, conversationID: conversationID) ?? false }, courseSchedule: courseSchedule, mutedChaoxingConversations: chaoxingMutedConversationNames, now: now, conversationID: conversationID, readMessageMemory: { [weak self] in self?.readChaoxingMemory() ?? "" }, refreshMessageMemory: { [weak self] in await self?.refreshChaoxingMemoryForAgent() ?? "" }, writeMessageMemory: { [weak self] in await self?.writeChaoxingMemory($0) ?? false })
    }

    internal func updateSchedulePlaceholder(_ messageID: UUID, _ content: String) {
        guard let index = scheduleMessages.firstIndex(where: { $0.id == messageID }) else { return }
        scheduleMessages[index].content = content
    }

    internal func updateSchedulePayload(_ messageID: UUID, _ payload: SchedulePayload) {
        guard let index = scheduleMessages.firstIndex(where: { $0.id == messageID }) else { return }
        var merged = scheduleMessages[index].schedulePayload ?? SchedulePayload()
        merged.merge(payload)
        scheduleMessages[index].schedulePayload = merged.isEmpty ? nil : merged
    }

    internal func updateScheduleReasoning(_ messageID: UUID, _ content: String) {
        guard let index = scheduleMessages.firstIndex(where: { $0.id == messageID }) else { return }
        scheduleMessages[index].reasoningContent = content
    }

    private func finishScheduleTask(_ taskID: UUID?) {
        guard taskID == nil || scheduleTaskID == taskID else { return }
        isScheduleAgentRunning = false; scheduleTask = nil; scheduleTaskID = nil
    }
}


// --- Merged from ChatViewModel+Skills.swift ---


extension ChatViewModel {
    // MARK: - Skills Management

    func addChatSkill(name: String, description: String, instructions: String, isEnabled: Bool = true) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDescription.isEmpty, !trimmedInstructions.isEmpty else { return }
        guard isValidAgentSkillName(trimmedName) else {
            errorMessage = "Skill name 必须是小写字母、数字或单连字符"
            return
        }
        chatSkills.append(ChatSkill(
            name: trimmedName,
            description: trimmedDescription,
            instructions: trimmedInstructions,
            isEnabled: isEnabled
        ))
        saveSettings()
    }

    func importChatSkillFolder(from url: URL) async {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            let skillURL = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillURL.path) else {
                throw APIError.httpError(400, "Skill 文件夹必须包含 SKILL.md")
            }

            let text: String
            if let utf8 = try? String(contentsOf: skillURL, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: skillURL)
            }

            var skill = try parseAgentSkillMarkdown(text, sourceName: url.lastPathComponent)
            skill.scripts = try loadSkillScripts(from: url)
            chatSkills.removeAll { $0.name == skill.name }
            chatSkills.append(skill)
            saveSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateChatSkill(_ skill: ChatSkill) {
        guard let i = chatSkills.firstIndex(where: { $0.id == skill.id }) else { return }
        guard isValidAgentSkillName(skill.name) else {
            errorMessage = "Skill name 必须是小写字母、数字或单连字符"
            return
        }
        chatSkills[i] = skill
        saveSettings()
    }

    func deleteChatSkill(_ skill: ChatSkill) {
        chatSkills.removeAll { $0.id == skill.id }
        saveSettings()
    }

    func setChatSkill(_ id: UUID, isEnabled: Bool) {
        guard let i = chatSkills.firstIndex(where: { $0.id == id }) else { return }
        chatSkills[i].isEnabled = isEnabled
        saveSettings()
    }

    internal func parseAgentSkillMarkdown(_ text: String, sourceName: String) throws -> ChatSkill {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            throw APIError.httpError(400, "Skill 必须以 YAML frontmatter 开头")
        }
        guard let endRange = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            throw APIError.httpError(400, "Skill 缺少结束 frontmatter 的 ---")
        }

        let frontmatter = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var bodyStart = endRange.upperBound
        if bodyStart < normalized.endIndex, normalized[bodyStart] == "\n" {
            bodyStart = normalized.index(after: bodyStart)
        }
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = parseFlatYAMLFrontmatter(frontmatter)
        guard let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw APIError.httpError(400, "Skill 缺少必需字段 name")
        }
        guard isValidAgentSkillName(name) else {
            throw APIError.httpError(400, "Skill name 必须是 1-64 位小写字母、数字或单连字符")
        }
        if sourceName != "SKILL", !sourceName.isEmpty, sourceName != name {
            throw APIError.httpError(400, "Skill name 需要和父目录名一致：\(name)")
        }
        guard let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            throw APIError.httpError(400, "Skill 缺少必需字段 description")
        }
        guard description.count <= 1024 else {
            throw APIError.httpError(400, "Skill description 不能超过 1024 字符")
        }
        guard !body.isEmpty else {
            throw APIError.httpError(400, "Skill instructions 不能为空")
        }

        return ChatSkill(
            name: name,
            description: description,
            instructions: body,
            license: fields["license"],
            compatibility: fields["compatibility"],
            allowedTools: fields["allowed-tools"],
            isEnabled: true
        )
    }

    private func parseFlatYAMLFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("  "), let currentKey {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                result[currentKey, default: ""].append("\n\(stripYAMLQuotes(continuation))")
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = stripYAMLQuotes(rawValue)
            currentKey = key
        }
        return result
    }

    internal func loadSkillScripts(from skillFolder: URL) throws -> [ChatSkillScript] {
        let scriptsURL = skillFolder.appendingPathComponent("scripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        guard let enumerator = FileManager.default.enumerator(
            at: scriptsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var scripts: [ChatSkillScript] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            guard isSupportedSkillScript(fileURL) else { continue }
            guard (values.fileSize ?? 0) <= ChatViewModel.maxSkillScriptBytes else {
                throw APIError.httpError(400, "\(fileURL.lastPathComponent) 超过 256KB，未导入")
            }

            let content: String
            if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
                content = utf8
            } else {
                content = try String(contentsOf: fileURL)
            }
            let relative = fileURL.path
                .replacingOccurrences(of: scriptsURL.path + "/", with: "")
            scripts.append(ChatSkillScript(
                name: fileURL.lastPathComponent,
                relativePath: "scripts/\(relative)",
                language: skillScriptLanguage(fileURL),
                content: content
            ))
        }
        return scripts.sorted { $0.relativePath < $1.relativePath }
    }

    private func isSupportedSkillScript(_ url: URL) -> Bool {
        ["sh", "zsh", "bash", "py", "js", "mjs"].contains(url.pathExtension.lowercased())
    }

    private func skillScriptLanguage(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "py": return "python"
        case "js", "mjs": return "node"
        case "bash": return "bash"
        default: return "shell"
        }
    }

    private func stripYAMLQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    internal func isValidAgentSkillName(_ name: String) -> Bool {
        guard (1...64).contains(name.count),
              !name.hasPrefix("-"),
              !name.hasSuffix("-"),
              !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar == "-" ||
                ("0"..."9").contains(String(scalar)) ||
                ("a"..."z").contains(String(scalar))
        }
    }
}
