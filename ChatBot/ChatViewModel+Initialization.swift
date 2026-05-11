import Foundation
import SwiftUI

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
}
