import Foundation
import EventKit

struct ScheduleAgentRunRequest {
    var userText: String
    var displayText: String?
    var placeholderID: UUID
    var messages: [AgentMsg]
    var context: SkillContext
    var provider: Provider
    var model: String
    var apiKey: String
    var thinkingBudget: Int
}

struct ScheduleAgentCallbacks {
    var progress: (String) -> Void
    var payload: (SchedulePayload) -> Void
    var reasoning: (String) -> Void
}

struct ScheduleAgentRunResult {
    var finalText: String
    var usedLegacyHarness: Bool
}

enum ScheduleSubAgentKind: String, CaseIterable {
    case calendar
    case reminders
    case courses
    case chaoxing
    case mutationPlanner

    var title: String {
        switch self {
        case .calendar: return "Calendar 子 Agent"
        case .reminders: return "Reminders 子 Agent"
        case .courses: return "课程表子 Agent"
        case .chaoxing: return "学习通子 Agent"
        case .mutationPlanner: return "变更草案子 Agent"
        }
    }
}

struct ScheduleSubAgentPlan: Equatable {
    var kind: ScheduleSubAgentKind
    var task: String
}

struct ScheduleMutationDraft: Codable, Equatable {
    var kind: String
    var title: String
    var detail: String
    var requiresConfirmation: Bool = true
}

struct ScheduleSubAgentReport: Equatable {
    var kind: ScheduleSubAgentKind
    var title: String
    var summary: String
    var itemCount: Int
}

struct ScheduleOrchestratorPlan: Equatable {
    var subAgents: [ScheduleSubAgentPlan]
    var expectsMutation: Bool
    var attentionWindowHours: Int = 48
    var mutationDrafts: [ScheduleMutationDraft] = []
}

@MainActor
final class ScheduleOrchestrator {
    private let harness: ScheduleHarness

    init(harness: ScheduleHarness) {
        self.harness = harness
    }

    func plan(for userText: String) -> ScheduleOrchestratorPlan {
        let lower = userText.lowercased()
        var readAgents: [ScheduleSubAgentPlan] = []

        if containsAny(lower, ["日历", "日程", "会议", "安排", "冲突", "calendar"]) {
            readAgents.append(.init(kind: .calendar, task: "读取系统日历并检查近期安排。"))
        }
        if containsAny(lower, ["提醒", "待办", "todo", "reminder", "完成"]) {
            readAgents.append(.init(kind: .reminders, task: "读取提醒事项并筛选待办/到期项。"))
        }
        if containsAny(lower, ["课", "课程", "课表", "教室", "调课", "停课", "补课"]) {
            readAgents.append(.init(kind: .courses, task: "读取本地课程表并检查课程相关变化。"))
        }
        if containsAny(lower, ["学习通", "作业", "ddl", "deadline", "通知", "消息"]) {
            readAgents.append(.init(kind: .chaoxing, task: "读取学习通作业和 memory 重点。"))
        }

        let expectsMutation = containsAny(lower, ["创建", "添加", "改成", "修改", "删除", "完成", "取消", "提醒我"])
        let drafts = mutationDrafts(for: userText)
        if readAgents.isEmpty {
            readAgents = [
                .init(kind: .calendar, task: "读取系统日历并检查近期安排。"),
                .init(kind: .reminders, task: "读取提醒事项并筛选待办/到期项。"),
                .init(kind: .courses, task: "读取本地课程表并检查课程相关变化。"),
                .init(kind: .chaoxing, task: "读取学习通作业和 memory 重点。")
            ]
        }
        var subAgents = Array(readAgents.prefix(expectsMutation ? 3 : 4))
        if expectsMutation {
            subAgents.append(.init(kind: .mutationPlanner, task: "生成待确认的日程/提醒变更草案，不直接写入系统。"))
        }

        return ScheduleOrchestratorPlan(
            subAgents: Array(subAgents.prefix(4)),
            expectsMutation: expectsMutation,
            attentionWindowHours: 48,
            mutationDrafts: drafts
        )
    }

    func run(_ request: ScheduleAgentRunRequest,
             callbacks: ScheduleAgentCallbacks) async throws -> ScheduleAgentRunResult {
        let plan = plan(for: request.userText)
        if !plan.subAgents.isEmpty {
            callbacks.progress("正在编排：\(plan.subAgents.map(\.kind.title).joined(separator: "、"))")
        }
        let reports = await collectReports(for: plan, context: request.context)
        let enrichedMessages = injectReports(reports, into: request.messages, windowHours: plan.attentionWindowHours)

        let finalText = try await harness.run(
            messages: enrichedMessages,
            context: request.context,
            provider: request.provider,
            model: request.model,
            apiKey: request.apiKey,
            thinkingBudget: request.thinkingBudget,
            onProgress: callbacks.progress,
            onPayload: callbacks.payload,
            onReasoning: callbacks.reasoning
        )

        return ScheduleAgentRunResult(finalText: finalText, usedLegacyHarness: true)
    }

    private func collectReports(for plan: ScheduleOrchestratorPlan,
                                context: SkillContext) async -> [ScheduleSubAgentReport] {
        var reports: [ScheduleSubAgentReport] = []
        for subAgent in plan.subAgents {
            switch subAgent.kind {
            case .calendar:
                reports.append(calendarReport(context: context, windowHours: plan.attentionWindowHours))
            case .reminders:
                reports.append(await remindersReport(context: context, windowHours: plan.attentionWindowHours))
            case .courses:
                reports.append(coursesReport(context: context, windowHours: plan.attentionWindowHours))
            case .chaoxing:
                reports.append(chaoxingReport(context: context))
            case .mutationPlanner:
                reports.append(mutationPlannerReport(drafts: plan.mutationDrafts))
            }
        }
        return reports
    }

    private func injectReports(_ reports: [ScheduleSubAgentReport],
                               into messages: [AgentMsg],
                               windowHours: Int) -> [AgentMsg] {
        guard !reports.isEmpty else { return messages }
        let block = """
        日程 Orchestrator 已先按固定子 Agent 做了轻量只读汇总。注意力窗口：未来 \(windowHours) 小时；越远权重越低。以下报告只用于减少无谓工具调用，若要写入/完成/删除，仍必须调用对应工具并经过 App 内确认。
        \(reports.map(formatReport).joined(separator: "\n"))
        """
        let reportMessage = AgentMsg(role: .system, content: block)
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else {
            return messages + [reportMessage]
        }
        var result = messages
        result.insert(reportMessage, at: lastUser)
        return result
    }

    private func calendarReport(context: SkillContext, windowHours: Int) -> ScheduleSubAgentReport {
        guard context.hasCalendarAccess else {
            return .init(kind: .calendar, title: "Calendar", summary: "未授权，不能读取系统日历。", itemCount: 0)
        }
        let end = context.now.addingTimeInterval(TimeInterval(windowHours) * 60 * 60)
        let events = context.remindersService.getEvents(startDate: context.now, endDate: end)
            .filter { !context.isLegacyImportedCourse($0) }
            .sorted { $0.startDate < $1.startDate }
        let lines = events.prefix(5).map { event in
            "\(shortDate(event.startDate, now: context.now)) \(event.title ?? "(无标题)")"
        }
        return .init(
            kind: .calendar,
            title: "Calendar",
            summary: lines.isEmpty ? "未来 \(windowHours) 小时没有系统日历事件。" : lines.joined(separator: "；"),
            itemCount: events.count
        )
    }

    private func remindersReport(context: SkillContext, windowHours: Int) async -> ScheduleSubAgentReport {
        guard context.hasRemindersAccess else {
            return .init(kind: .reminders, title: "Reminders", summary: "未授权，不能读取提醒事项。", itemCount: 0)
        }
        let end = context.now.addingTimeInterval(TimeInterval(windowHours) * 60 * 60)
        let reminders = await context.remindersService.getReminders(includeCompleted: false)
        let focused = reminders
            .filter { reminder in
                guard let comps = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: comps) else { return false }
                return due <= end
            }
            .sorted { lhs, rhs in
                let left = lhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                let right = rhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                return left < right
            }
        let lines = focused.prefix(5).map { reminder in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            return "\(due.map { shortDate($0, now: context.now) } ?? "无截止") \(reminder.title ?? "(无标题)")"
        }
        return .init(
            kind: .reminders,
            title: "Reminders",
            summary: lines.isEmpty ? "未来 \(windowHours) 小时没有到期提醒。" : lines.joined(separator: "；"),
            itemCount: focused.count
        )
    }

    private func coursesReport(context: SkillContext, windowHours: Int) -> ScheduleSubAgentReport {
        let end = context.now.addingTimeInterval(TimeInterval(windowHours) * 60 * 60)
        let courses = context.localCourses(startDate: context.now, endDate: end, query: nil)
            .sorted { $0.startDate < $1.startDate }
        let lines = courses.prefix(5).map { course in
            "\(shortDate(course.startDate, now: context.now)) \(course.title)"
        }
        return .init(
            kind: .courses,
            title: "课程表",
            summary: lines.isEmpty ? "未来 \(windowHours) 小时没有本地课程。" : lines.joined(separator: "；"),
            itemCount: courses.count
        )
    }

    private func chaoxingReport(context: SkillContext) -> ScheduleSubAgentReport {
        let memory = context.readMessageMemory()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        if memory.isEmpty {
            summary = "本地学习通 memory 为空；如用户问题依赖学习通消息，应调用 refresh_message_memory。"
        } else {
            summary = "本地学习通 memory 可用，优先读取 memory；只有原文/诊断需求再读取消息。摘要预览：\(compact(memory, limit: 160))"
        }
        return .init(kind: .chaoxing, title: "学习通", summary: summary, itemCount: memory.isEmpty ? 0 : 1)
    }

    private func mutationPlannerReport(drafts: [ScheduleMutationDraft]) -> ScheduleSubAgentReport {
        let draftText = drafts.isEmpty
            ? "检测到可能的写入意图，但无法可靠归类；必须先查 ID/补齐时间，再调用对应工具。"
            : drafts.map { draft in
                "\(draft.kind)：\(draft.title)；\(draft.detail)"
            }.joined(separator: "；")
        return .init(
            kind: .mutationPlanner,
            title: "变更草案",
            summary: "\(draftText)。创建、修改、完成、删除前必须调用对应工具触发 App 内确认；工具失败时不能只回复“完成”。",
            itemCount: max(drafts.count, 1)
        )
    }

    private func mutationDrafts(for userText: String) -> [ScheduleMutationDraft] {
        let lower = userText.lowercased()
        var drafts: [ScheduleMutationDraft] = []
        if containsAny(lower, ["提醒我", "添加提醒", "创建提醒", "新建提醒"]) {
            drafts.append(.init(kind: "create_reminder", title: "创建提醒事项", detail: compact(userText, limit: 80)))
        } else if containsAny(lower, ["添加日程", "创建日程", "新建日程", "添加事件", "创建事件", "日历加"]) {
            drafts.append(.init(kind: "create_calendar_event", title: "创建日历事件", detail: compact(userText, limit: 80)))
        } else if containsAny(lower, ["完成", "标记完成", "做完", "已做"]) {
            drafts.append(.init(kind: "complete_reminder", title: "完成提醒事项", detail: "需要先通过 list_reminders 找到目标 ID。"))
        } else if containsAny(lower, ["删除", "取消"]) {
            drafts.append(.init(kind: "delete_item", title: "删除或取消事项", detail: "需要先查明目标类型和 ID，再选择 delete_reminder 或 delete_calendar_event。"))
        } else if containsAny(lower, ["改成", "修改", "挪到", "推迟", "提前"]) {
            drafts.append(.init(kind: "update_item", title: "修改事项", detail: "需要先查明目标类型和 ID，再选择 update_reminder 或 update_calendar_event。"))
        } else if containsAny(lower, ["创建", "添加", "新建"]) {
            drafts.append(.init(kind: "create_item", title: "创建事项", detail: "需要根据用户语义选择提醒事项或日历事件。"))
        }
        return drafts
    }

    private func formatReport(_ report: ScheduleSubAgentReport) -> String {
        "- \(report.kind.title)：\(report.summary)（命中 \(report.itemCount)）"
    }

    private func shortDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }

    private func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "..." : oneLine
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }
}
