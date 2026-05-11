import Foundation
import SwiftUI

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
                        activeToolStatus = "已完成：\(result.2)"
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
        let itemsArray = call.args["items"] as? [[String: Any]] ?? []
        let items = itemsArray.compactMap { dict -> ChatListItem? in
            guard let title = dict["title"] as? String else { return nil }
            return ChatListItem(
                title: title,
                detail: dict["detail"] as? String,
                badge: dict["badge"] as? String,
                priority: dict["priority"] as? String,
                isDone: dict["isDone"] as? Bool
            )
        }
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
        
        let result = await harness.runTool(
            call.name,
            args: call.args,
            now: Date(),
            cachedReminders: cachedAgentReminders,
            cachedEvents: cachedAgentEvents,
            hasRemindersAccess: hasRemindersAccess,
            hasCalendarAccess: hasCalendarAccess,
            courseSchedule: courseSchedule,
            importantChaoxingMessages: chaoxingMessageInsights,
            confirmationHandler: { [weak self] confirmation in
                await self?.confirmScheduleAction(confirmation) ?? false
            }
        )
        
        if result.success {
            refreshScheduleSidebar()
        }
        return result
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
            let keywords = tool.name.components(separatedBy: "_") + [tool.description.lowercased()]
            for kw in keywords where !kw.isEmpty {
                if lower.contains(kw) { return true }
            }
            if (lower.contains("学") || lower.contains("课") || lower.contains("作业") || lower.contains("考试")) && 
                (tool.name.contains("chaoxing") || tool.name.contains("course") || tool.name.contains("memory")) {
                return true
            }
            if (lower.contains("提醒") || lower.contains("日历") || lower.contains("会") || lower.contains("点")) && 
                (tool.name.contains("reminder") || tool.name.contains("calendar")) {
                return true
            }
            return false
        }
    }
}
