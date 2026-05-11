import Foundation
import SwiftUI

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
                markChatResponseStopped(conversationID: convID, messageID: assistantID)
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
