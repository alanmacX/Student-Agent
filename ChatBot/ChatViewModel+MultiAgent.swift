import Foundation
import SwiftUI

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
