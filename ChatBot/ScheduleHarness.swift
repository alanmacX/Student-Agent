import Foundation
import EventKit

// MARK: - Harness

/// Owns the agentic loop for the Schedule tab.
/// ChatViewModel is reduced to an orchestrator:
///   build context → call harness.run → update UI from callbacks.
///
/// To add a new capability, create a ScheduleSkill and register it in `skills`.
/// See SKILL_SPEC.md for the full authoring guide.
@MainActor
final class ScheduleHarness {

    // ── Skill registry ────────────────────────────────────────────────────────
    // Order determines the position in the tools array sent to the LLM.
    // Add new skills here; no other file needs to change.
    private let skills: [any ScheduleSkill] = [
        ListReminderListsSkill(),
        ListRemindersSkill(),
        CreateReminderSkill(),
        UpdateReminderSkill(),
        CompleteReminderSkill(),
        DeleteReminderSkill(),
        ListCoursesSkill(),
        ListCalendarsSkill(),
        ListCalendarEventsSkill(),
        CreateCalendarEventSkill(),
        UpdateCalendarEventSkill(),
        DeleteCalendarEventSkill(),
        GetChaoxingAssignmentsSkill(),
        GetChaoxingMessagesSkill(),
        DiagnoseChaoxingSkill(),
        DiagnoseChaoxingIMSkill(),
        DiagnoseChaoxingInboxSkill(),
        ReadMessageMemorySkill(),
        RefreshMessageMemorySkill(),
        DeleteMessageMemorySkill()
    ]

    var tools: [AgentTool] { skills.map(\.tool) }

    func runTool(_ call: ToolCall, context: SkillContext) async -> SkillResult {
        await dispatch(call, skills: skills, context: context)
    }

    // ── System Prompt ─────────────────────────────────────────────────────────
    // Injects the current local time WITH explicit UTC offset so the LLM
    // always knows the timezone and can produce correct ISO-8601 dates.

    func buildStaticSystemPrompt(customSchedulePrompt: String) -> String {
        let custom = customSchedulePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let customBlock = custom.isEmpty ? "" : "\n用户自定义日程 Prompt：\n\(custom)"
        
        return """
        你是 ChatBot 的日程 Agent，主要管理 macOS Reminders（提醒事项）和 Calendar（日历事件），也能读取课程表、学习通作业和学习通消息。
        你可以读取、创建、更新、完成、删除提醒事项，也可以读取、创建、更新、删除日历事件；可以读取学习通作业、学习通 memory，并在 memory 不足时触发 refresh_message_memory。如果你认为某条 memory 不重要或用户明确要求删除，可以使用 delete_message_memory 工具将其删除。只有在用户明确要求修改、完成或删除时才执行写操作。
        课程表是 App 内本地导入的数据，不属于系统 Calendar；需要了解上课时间时使用 list_courses。不要为了导入、查看或规划课程表而创建 Calendar 事件。
        不要因为"考试、期中、作业截止、会议、活动、通知"自动查询课程表；只有用户明确提到具体课程名、课程表、上课安排、调课、停课、补课或换教室时，才读取课程表。
        需要操作具体提醒事项或日历事件时，先通过工具查到 ID。
        工具结果默认只给你阅读，不自动用 App 原生 UI 展示。只有用户明确要看列表/卡片/课程表，或你判断原生 UI 能显著降低阅读成本时，才在工具参数里设置 show_in_ui=true。
        最终回复使用中文，只写一句简洁摘要；不要重复完整列表，不要输出 Markdown 列表、表格、标题或代码块。\(customBlock)
        """
    }

    func buildDynamicContextPrompt(now: Date) -> String {
        let tz        = TimeZone.current
        let offsetSec = tz.secondsFromGMT(for: now)
        let sign      = offsetSec >= 0 ? "+" : "-"
        let absOff    = Swift.abs(offsetSec)
        let isoOffset = String(format: "%@%02d:%02d", sign, absOff / 3600, (absOff % 3600) / 60)
        let tzStr     = "UTC\(isoOffset)"

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

        return """
        【当前时间】\(nowISO)（\(weekday)，\(tzStr)）
        今天日期是 \(nowISO.prefix(10))，时区 \(tzStr)。当用户说"今天""明天""下周一"等相对日期时，以上述当前时间为基准计算出绝对日期再使用。
        所有工具的日期参数必须使用 ISO-8601 格式并含时区偏移，例如：\(nowISO.prefix(10))T21:00:00\(isoOffset)。
        """
    }

    // ── Turn Context ─────────────────────────────────────────────────────────
    // Built from data cached during the last refreshScheduleSidebar() call.
    // No async fetch here → zero performance cost per agent turn.
    // The prompt includes a note so the LLM knows to call tools for fresh data.

    func makeTurnContextPrompt(
        now: Date,
        cachedReminders: [EKReminder],
        cachedEvents: [EKEvent],
        hasRemindersAccess: Bool,
        hasCalendarAccess: Bool,
        courseSchedule: [ScheduleCalendarEventItem],
        importantChaoxingMessages: [ScheduleChaoxingMessageInsightItem],
        isLegacyImportedCourse: (EKEvent) -> Bool
    ) -> String {
        let attentionWindowHours = 48
        let rangeEnd = now.addingTimeInterval(TimeInterval(attentionWindowHours) * 60 * 60)

        var sections: [String] = [
            """
            本轮 App 已预读取日程上下文（快照可能有延迟，若需精确或实时数据请调用工具）。
            权限：Reminders=\(hasRemindersAccess ? "已授权" : "未授权")，Calendar=\(hasCalendarAccess ? "已授权" : "未授权")，本地课程=\(courseSchedule.count) 条，学习通=\(ChaoxingService.shared.isLoggedIn ? "已登录(\(ChaoxingService.shared.userName))" : "未登录")。
            """
        ]

        if hasRemindersAccess {
            let focused = cachedReminders
                .filter { reminder in
                    guard let comps = reminder.dueDateComponents,
                          let due = Calendar.current.date(from: comps) else { return false }
                    return due <= rangeEnd
                }
                .sorted { lhs, rhs in
                    let left = lhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    let right = rhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    return left < right
                }
            let visible = Array(focused.prefix(16))
            sections.append("""
            未来 \(attentionWindowHours) 小时内到期提醒事项（\(focused.count) 条，最多列 16 条；如需更远或无截止事项请调用工具）：
            \(visible.isEmpty ? "无 48 小时内到期提醒事项。" : visible.map(RemindersService.format).joined(separator: "\n\n"))
            """)
        } else {
            sections.append("提醒事项：未授权，不能读取 Reminders。")
        }

        if hasCalendarAccess {
            let events = cachedEvents
                .filter { !isLegacyImportedCourse($0) && $0.startDate <= rangeEnd && $0.endDate >= now }
                .sorted { $0.startDate < $1.startDate }
            let visible = Array(events.prefix(16))
            sections.append("""
            未来 \(attentionWindowHours) 小时日历事件（\(events.count) 条，最多列 16 条；如需更远范围请调用工具）：
            \(visible.isEmpty ? "无日历事件。" : visible.map(formatEventText).joined(separator: "\n\n"))
            """)
        } else {
            sections.append("日历事件：未授权，不能读取 Calendar。")
        }

        let courses = courseSchedule
            .filter { $0.endDate >= now && $0.startDate <= rangeEnd }
            .sorted { $0.startDate < $1.startDate }
        if !courses.isEmpty {
            let visible = Array(courses.prefix(16))
            sections.append("""
            未来 \(attentionWindowHours) 小时本地课程表（\(courses.count) 条，最多列 16 条；如需更远课程请调用工具）：
            \(visible.map(formatCourseText).joined(separator: "\n\n"))
            """)
        }

        if !importantChaoxingMessages.isEmpty {
            sections.append("""
            已提取的重要学习通消息（\(importantChaoxingMessages.count) 条，最多列 8 条；需要最新消息时调用 memory 工具）：
            \(importantChaoxingMessages.prefix(8).map(formatChaoxingMessageInsightText).joined(separator: "\n"))
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    // ── Message Builder ───────────────────────────────────────────────────────

    func buildMessages(
        staticSystemContent: String,
        dynamicContext: String,
        scheduleMessages: [Message],
        excluding placeholderID: UUID,
        contextResetAt: Date?,
        contextWindowSize: Int = 20
    ) -> [AgentMsg] {
        var result = [AgentMsg(role: .system, content: staticSystemContent)]

        let eligible = scheduleMessages
            .filter { $0.id != placeholderID && $0.role != .system }
            .filter { msg in
                guard let start = contextResetAt else { return true }
                return msg.timestamp > start
            }

        let windowed = eligible.count > contextWindowSize
            ? Array(eligible.suffix(contextWindowSize))
            : eligible

        if windowed.count < eligible.count {
            result.append(AgentMsg(
                role: .system,
                content: "（注：较早的 \(eligible.count - windowed.count) 条对话消息已被截断以控制上下文长度。）"
            ))
        }
        result.append(contentsOf: windowed.map {
            AgentMsg(role: $0.role == .user ? .user : .assistant, content: $0.content)
        })
        
        // Dynamic context at the end
        result.append(AgentMsg(role: .system, content: dynamicContext))
        
        return result
    }

    // ── Agent Loop ────────────────────────────────────────────────────────────
    // Max 8 iterations. Sub-agent planning lives in ScheduleOrchestrator;
    // this harness only runs the tool loop for the final answering agent.
    // Tool calls run in parallel.
    // Callbacks fire on @MainActor so the ViewModel can update UI directly.
    // thinkingBudget: budget_tokens for Anthropic extended thinking (0 = off).

    func run(
        messages initialMessages: [AgentMsg],
        context: SkillContext,
        provider: Provider,
        model: String,
        apiKey: String,
        thinkingBudget: Int = 0,
        onProgress: @escaping (String) -> Void,
        onPayload: @escaping (SchedulePayload) -> Void,
        onReasoning: @escaping (String) -> Void
    ) async throws -> String {
        let activeTools = skills.map(\.tool)
        let maxIterations = 8

        var agentMessages    = initialMessages
        var finalText        = ""
        var reasoningParts: [String] = []
        var displayPayload   = SchedulePayload()
        var failureSummaries: [String] = []
        var reachedFinalAnswer = false

        for _ in 0..<maxIterations {
            try Task.checkCancellation()

            agentMessages = trimIntraTurnContext(agentMessages, maxToolPairs: 6)
            let response  = try await agentComplete(
                messages: agentMessages, tools: activeTools,
                provider: provider, model: model, apiKey: apiKey,
                thinkingBudget: thinkingBudget
            )
            try Task.checkCancellation()

            if let reasoning = response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reasoning.isEmpty {
                reasoningParts.append(reasoning)
                onReasoning(reasoningParts.joined(separator: "\n\n"))
            }

            guard let calls = response.toolCalls, !calls.isEmpty else {
                finalText = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                reachedFinalAnswer = true
                break
            }

            onProgress("正在处理…")
            agentMessages.append(AgentMsg(
                role: .assistant,
                content: response.text,
                reasoningContent: response.reasoningContent,
                toolCalls: calls
            ))

            // Parallel tool execution (Claude Code pattern)
            let results: [(Int, SkillResult)] = await withTaskGroup(of: (Int, SkillResult).self) { group in
                for (idx, call) in calls.enumerated() {
                    group.addTask { [call] in
                        let result = await self.dispatch(call, skills: self.skills, context: context)
                        return (idx, result)
                    }
                }
                var collected: [(Int, SkillResult)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }
            }

            try Task.checkCancellation()
            for (idx, result) in results {
                let call = calls[idx]
                // Tool result truncation (Claude Code pattern)
                agentMessages.append(AgentMsg(
                    role: .tool,
                    content: truncate(result.content),
                    toolCallID: call.id,
                    toolName: call.name
                ))
                if let payload = result.payload {
                    displayPayload.merge(payload)
                    onPayload(displayPayload)
                }
                if result.content.hasPrefix("错误:") {
                    failureSummaries.append("\(call.name): \(String(result.content.prefix(120)))")
                }
            }
        }

        if finalText.isEmpty {
            if !failureSummaries.isEmpty {
                return Self.partialFailureSummary(failureSummaries)
            }
            return reachedFinalAnswer
                ? "模型没有返回可显示的最终回答。"
                : "任务未完成：日程 Agent 达到工具调用轮次上限，但没有生成最终回答。"
        }
        if Self.isBareCompletionText(finalText), !failureSummaries.isEmpty {
            return Self.partialFailureSummary(failureSummaries)
        }
        return finalText
    }

    private static func isBareCompletionText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ "))
            .lowercased()
        return ["完成", "done", "ok", "好的", "已完成"].contains(normalized)
    }

    private static func partialFailureSummary(_ failures: [String]) -> String {
        let unique = Array(NSOrderedSet(array: failures).compactMap { $0 as? String }).prefix(4)
        return """
        任务没有完全完成：有 \(failures.count) 个工具失败。
        \(unique.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    // ── Tool Dispatch ─────────────────────────────────────────────────────────

    private func dispatch(_ call: ToolCall, skills: [any ScheduleSkill], context: SkillContext) async -> SkillResult {
        guard let skill = skills.first(where: { $0.tool.name == call.name }) else {
            return .error("错误: 未知工具 \(call.name)。")
        }
        let showUI = agentBoolArg(call.args, "show_in_ui") ?? false
        return await skill.run(args: call.args, showUI: showUI, context: context)
    }

    // ── Harness Helpers ───────────────────────────────────────────────────────

    private func truncate(_ content: String, maxChars: Int = 8_000) -> String {
        guard content.count > maxChars else { return content }
        return "\(content.prefix(maxChars))\n…（内容已截断，共 \(content.count) 字符，仅传递前 \(maxChars) 字符）"
    }

    /// Keeps intra-turn messages from growing unboundedly when the agent calls
    /// many tools in one pass.  Preserves system/user anchors and the last
    /// `maxToolPairs` assistant↔tool round-trips.
    private func trimIntraTurnContext(_ messages: [AgentMsg], maxToolPairs: Int) -> [AgentMsg] {
        let anchors    = messages.filter { $0.role == .system || $0.role == .user }
        let toolRound  = messages.filter { $0.role == .assistant || $0.role == .tool }
        guard toolRound.count > maxToolPairs * 2 else { return messages }
        return anchors + Array(toolRound.suffix(maxToolPairs * 2))
    }
}
