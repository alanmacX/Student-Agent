import Foundation
import SwiftUI
import AppKit
import EventKit

extension ChatViewModel {
    // MARK: - Agents Shared Logic (Schedule, Memory, Companion)

    // MARK: - Schedule Agent

    func startSendingScheduleAgentMessage(_ prompt: String, displayText: String? = nil) {
        guard !isScheduleAgentRunning else { return }
        isScheduleAgentRunning = true
        scheduleErrorMessage = nil
        let msgID = UUID()
        let display = displayText ?? prompt
        scheduleMessages.append(Message(id: msgID, role: .user, content: display, timestamp: Date()))
        
        let taskID = UUID()
        scheduleTaskID = taskID
        scheduleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.executeScheduleAgent(prompt: prompt)
                guard !Task.isCancelled, self.scheduleTaskID == taskID else { return }
                await MainActor.run {
                    self.scheduleMessages.append(Message(id: UUID(), role: .assistant, content: response, timestamp: Date()))
                    self.finishScheduleTask(taskID)
                    Task { await self.refreshScheduleSidebar() }
                }
            } catch {
                guard !Task.isCancelled, self.scheduleTaskID == taskID else { return }
                await MainActor.run {
                    self.scheduleErrorMessage = error.localizedDescription
                    self.finishScheduleTask(taskID)
                }
            }
        }
    }

    private func executeScheduleAgent(prompt: String) async throws -> String {
        let provider = activeAgentProvider
        let key = apiKey(for: provider)
        guard !key.isEmpty else { throw APIError.httpError(401, "未配置 API Key (\(provider.name))") }
        
        let now = Date()
        let systemPrompt = scheduleAgentPrompt + "\n\n当前时间: \(now.formatted())\n"
        
        var history = scheduleMessages.filter { msg in
            if let resetAt = scheduleContextResetAt {
                return msg.timestamp > resetAt
            }
            return true
        }.map { AgentMsg(role: $0.role == .user ? .user : .assistant, content: $0.content) }
        
        if history.last?.content == prompt { history.removeLast() }
        
        let context = [AgentMsg(role: .system, content: systemPrompt)] + history + [AgentMsg(role: .user, content: prompt)]
        
        let result = try await agentComplete(
            messages: context,
            tools: scheduleOrchestrator.tools,
            provider: provider,
            model: economicalModel(for: provider),
            apiKey: key,
            thinkingBudget: agentThinkingBudgetTokens
        )
        
        if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
            let toolResults = try await scheduleOrchestrator.handle(toolCalls: toolCalls, viewModel: self)
            let updatedContext = context + [AgentMsg(role: .assistant, content: result.text ?? "", toolCalls: toolCalls)] + toolResults
            let finalResult = try await agentComplete(
                messages: updatedContext,
                tools: scheduleOrchestrator.tools,
                provider: provider,
                model: economicalModel(for: provider),
                apiKey: key
            )
            return finalResult.text ?? "任务执行完毕。"
        }
        
        return result.text ?? "未收到有效回复。"
    }

    private func finishScheduleTask(_ taskID: UUID?) {
        guard taskID == nil || scheduleTaskID == taskID else { return }
        isScheduleAgentRunning = false; scheduleTask = nil; scheduleTaskID = nil
    }

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
