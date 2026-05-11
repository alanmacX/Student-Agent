import Foundation
import EventKit

// MARK: - Agent Schema Helpers
// Free functions shared by ScheduleSkill, ScheduleHarness, and ChatViewModel chat tools.

func agentObjectSchema(properties: [String: Any], required: [String] = []) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false
    ]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

func agentStringSchema(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

func agentBoolSchema(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}

func agentIntSchema(_ description: String) -> [String: Any] {
    ["type": "integer", "description": description]
}

// MARK: - Argument Parsers

func agentStringArg(_ args: [String: Any], _ key: String) -> String? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
}

func agentBoolArg(_ args: [String: Any], _ key: String) -> Bool? {
    if let bool = args[key] as? Bool { return bool }
    if let number = args[key] as? NSNumber { return number.boolValue }
    if let string = args[key] as? String {
        return ["true", "yes", "1", "是"].contains(string.lowercased())
    }
    return nil
}

func agentIntArg(_ args: [String: Any], _ key: String) -> Int? {
    if let int = args[key] as? Int { return int }
    if let number = args[key] as? NSNumber { return number.intValue }
    if let string = args[key] as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

func agentStringArrayArg(_ args: [String: Any], _ key: String) -> [String] {
    if let array = args[key] as? [String] { return array }
    if let array = args[key] as? [Any] {
        return array.compactMap { value in
            guard !(value is NSNull) else { return nil }
            return String(describing: value)
        }
    }
    if let single = agentStringArg(args, key), !single.isEmpty { return [single] }
    return []
}

func agentParseDate(_ value: String?) throws -> Date? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: raw) { return date }
    for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                   "yyyy-MM-dd", "yyyy/M/d HH:mm", "yyyy/M/d HH:mm:ss", "yyyy/M/d"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    throw APIError.httpError(400, "无法解析日期: \(raw)")
}

func agentFormatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

/// Formats a deadline as a human-readable relative string for LLM consumption.
/// e.g. "今天 23:59 截止", "明天 18:00 截止", "周五 12:00 截止", "6月20日 14:00 截止", "已逾期（5月1日）"
func agentFormatRelativeDeadline(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let nowStart = cal.startOfDay(for: now)
    let dateStart = cal.startOfDay(for: date)
    let diff = cal.dateComponents([.day], from: nowStart, to: dateStart).day ?? 0

    let timeFmt = DateFormatter()
    timeFmt.locale = Locale(identifier: "zh_CN")
    timeFmt.dateFormat = "HH:mm"
    let timeStr = timeFmt.string(from: date)

    if diff < 0 {
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "M月d日"
        return "已逾期（\(dateFmt.string(from: date))）"
    }
    switch diff {
    case 0: return "今天 \(timeStr) 截止"
    case 1: return "明天 \(timeStr) 截止"
    case 2...6:
        let wdFmt = DateFormatter()
        wdFmt.locale = Locale(identifier: "zh_CN")
        wdFmt.dateFormat = "EEEE"
        return "\(wdFmt.string(from: date)) \(timeStr) 截止"
    default:
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "zh_CN")
        dateFmt.dateFormat = "M月d日"
        return "\(dateFmt.string(from: date)) \(timeStr) 截止"
    }
}

/// Returns a formatted "当前时间" string for injection into agent system prompts.
func agentFormatCurrentTime(_ date: Date = Date()) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "zh_CN")
    fmt.dateFormat = "yyyy年M月d日 EEEE HH:mm"
    return fmt.string(from: date)
}

func agentCompareReminders(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
    let lDate = lhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    let rDate = rhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    switch (lDate, rDate) {
    case let (l?, r?): return l < r
    case (_?, nil):    return true
    case (nil, _?):    return false
    default:           return (lhs.title ?? "") < (rhs.title ?? "")
    }
}

// MARK: - Skill Mutation

enum SkillMutationKind {
    case createReminder, createEvent
    case updateReminder, completeReminder, deleteReminder
    case updateEvent, deleteEvent
    case importCourses

    var title: String {
        switch self {
        case .createReminder:   return "确认创建提醒事项"
        case .createEvent:      return "确认创建日历事件"
        case .updateReminder:   return "确认修改提醒事项"
        case .completeReminder: return "确认完成提醒事项"
        case .deleteReminder:   return "确认删除提醒事项"
        case .updateEvent:      return "确认修改日历事件"
        case .deleteEvent:      return "确认删除日历事件"
        case .importCourses:    return "确认导入课程表"
        }
    }

    var confirmButton: String {
        switch self {
        case .createReminder, .createEvent: return "确认创建"
        case .updateReminder, .updateEvent: return "确认修改"
        case .completeReminder:             return "确认完成"
        case .deleteReminder, .deleteEvent: return "确认删除"
        case .importCourses:               return "确认导入"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteReminder, .deleteEvent: return true
        default: return false
        }
    }
}

// MARK: - Skill Context
// Injected once per agent turn; skills call back via closures instead of
// reaching directly into ChatViewModel.

struct SkillContext {
    let remindersService: RemindersService
    let hasRemindersAccess: Bool
    let hasCalendarAccess: Bool
    /// Returns true if the EKEvent was imported via the legacy course importer.
    let isLegacyImportedCourse: (EKEvent) -> Bool
    /// Pause the agent and show an app-native confirmation dialog.
    let confirmMutation: (SkillMutationKind, _ entitySummary: String, _ changesSummary: String) async -> Bool
    let courseSchedule: [ScheduleCalendarEventItem]
    /// 学习通群聊屏蔽列表。
    let mutedChaoxingConversations: Set<String>
    /// Current wall-clock time, injected once per Harness.run() call for consistency.
    let now: Date
    let conversationID: UUID?
    /// Read the persisted Chaoxing message memory JSON string.
    let readMessageMemory: () -> String
    /// Trigger the Chaoxing Memory Agent when current memory is stale or insufficient.
    let refreshMessageMemory: () async -> String
    /// Overwrite the Chaoxing message memory with new JSON. Returns success.
    let writeMessageMemory: (_ json: String) async -> Bool
}

extension SkillContext {
    func localCourses(startDate: Date, endDate: Date, query: String?) -> [ScheduleCalendarEventItem] {
        courseSchedule.filter { course in
            guard course.endDate >= startDate && course.startDate <= endDate else { return false }
            guard let query, !query.isEmpty else { return true }
            return course.title.lowercased().contains(query) ||
                course.calendarName.lowercased().contains(query) ||
                (course.location ?? "").lowercased().contains(query) ||
                (course.notes ?? "").lowercased().contains(query)
        }
    }
}

// MARK: - Skill Result

struct SkillResult {
    let content: String
    let payload: SchedulePayload?

    init(_ content: String, payload: SchedulePayload? = nil) {
        self.content = content
        self.payload = payload
    }

    static func error(_ message: String) -> SkillResult { SkillResult(message) }
}

// MARK: - Protocol
// Every skill is a value type. Add a new skill by:
// 1. Creating a struct that conforms to ScheduleSkill
// 2. Adding it to ScheduleHarness.skills (see SKILL_SPEC.md)

@MainActor
protocol ScheduleSkill {
    var tool: AgentTool { get }
    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult
}

// MARK: - Shared tool property helpers (file-private)

private func uiProp() -> [String: Any] {
    agentBoolSchema("Set true only when the user explicitly wants an app-native list/card/table, or when native UI would clearly make the result easier to scan. Keep false for internal lookups, ID searches, and ordinary short answers.")
}

private func tp(_ extra: [String: Any] = [:]) -> [String: Any] {
    var result = extra
    result["show_in_ui"] = uiProp()
    return result
}

// MARK: - Formatting helpers (internal, also used by ScheduleHarness)

func formatEventText(_ event: EKEvent) -> String {
    var parts = [
        "事件: \(event.title ?? "(无标题)")",
        "日历: \(event.calendar.title)",
        "开始: \(agentFormatDate(event.startDate))",
        "结束: \(agentFormatDate(event.endDate))",
        "ID: \(event.eventIdentifier ?? "")"
    ]
    if let loc = event.location,   !loc.isEmpty   { parts.append("地点: \(loc)") }
    if let notes = event.notes,    !notes.isEmpty  { parts.append("备注: \(notes)") }
    return parts.joined(separator: "\n")
}

func formatCourseText(_ course: ScheduleCalendarEventItem) -> String {
    var parts = [
        "课程: \(course.title)",
        "时间: \(agentFormatDate(course.startDate)) - \(agentFormatDate(course.endDate))",
        "ID: \(course.id)"
    ]
    if let loc = course.location, !loc.isEmpty   { parts.append("地点: \(loc)") }
    if let notes = course.notes, !notes.isEmpty  { parts.append("备注: \(notes)") }
    return parts.joined(separator: "\n")
}

func formatChaoxingMessageInsightText(_ item: ScheduleChaoxingMessageInsightItem) -> String {
    var parts = [
        "• [\(agentFormatDate(item.sentAt))][\(item.conversationName)] \(item.title)：\(item.summary)"
    ]
    if !item.reason.isEmpty { parts.append("原因：\(item.reason)") }
    if let action = item.actionHint, !action.isEmpty { parts.append("建议：\(action)") }
    return parts.joined(separator: "；")
}

private func reminderSummaryText(_ r: EKReminder) -> String {
    var parts = ["标题：\(r.title ?? "(无标题)")", "清单：\(r.calendar.title)"]
    if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
        parts.append("截止：\(agentFormatDate(date))")
    }
    if let notes = r.notes, !notes.isEmpty { parts.append("备注：\(notes)") }
    return parts.joined(separator: "\n")
}

private func createReminderSummaryText(dueDate: Date?, notes: String?, listName: String?) -> String {
    var parts: [String] = []
    if let listName, !listName.isEmpty { parts.append("清单：\(listName)") }
    if let dueDate { parts.append("截止时间：\(agentFormatDate(dueDate))") }
    if let notes, !notes.isEmpty { parts.append("备注：\(notes)") }
    return parts.isEmpty ? "创建提醒事项" : parts.joined(separator: "\n")
}

private func updateReminderSummaryText(title: String?, dueDate: Date?, notes: String?, clearDueDate: Bool) -> String {
    var parts: [String] = []
    if let title      { parts.append("标题改为：\(title.isEmpty ? "(空)" : title)") }
    if let dueDate    { parts.append("截止时间改为：\(agentFormatDate(dueDate))") }
    if clearDueDate   { parts.append("移除截止时间") }
    if let notes      { parts.append("备注改为：\(notes.isEmpty ? "(空)" : notes)") }
    return parts.isEmpty ? "更新提醒事项" : parts.joined(separator: "\n")
}

private func eventSummaryText(_ e: EKEvent) -> String {
    var parts = [
        "标题：\(e.title ?? "(无标题)")",
        "日历：\(e.calendar.title)",
        "时间：\(agentFormatDate(e.startDate)) - \(agentFormatDate(e.endDate))"
    ]
    if let loc = e.location, !loc.isEmpty    { parts.append("地点：\(loc)") }
    if let notes = e.notes, !notes.isEmpty   { parts.append("备注：\(notes)") }
    return parts.joined(separator: "\n")
}

private func createEventSummaryText(startDate: Date, endDate: Date, notes: String?, location: String?, calendarName: String?, isAllDay: Bool) -> String {
    var parts = ["时间：\(agentFormatDate(startDate)) - \(agentFormatDate(endDate))"]
    if isAllDay { parts.append("全天事件") }
    if let calendarName, !calendarName.isEmpty { parts.append("日历：\(calendarName)") }
    if let location, !location.isEmpty { parts.append("地点：\(location)") }
    if let notes, !notes.isEmpty { parts.append("备注：\(notes)") }
    return parts.joined(separator: "\n")
}

private func updateEventSummaryText(title: String?, startDate: Date?, endDate: Date?, notes: String?, location: String?) -> String {
    var parts: [String] = []
    if let title     { parts.append("标题改为：\(title.isEmpty ? "(空)" : title)") }
    if let startDate { parts.append("开始时间改为：\(agentFormatDate(startDate))") }
    if let endDate   { parts.append("结束时间改为：\(agentFormatDate(endDate))") }
    if let location  { parts.append("地点改为：\(location.isEmpty ? "(空)" : location)") }
    if let notes     { parts.append("备注改为：\(notes.isEmpty ? "(空)" : notes)") }
    return parts.isEmpty ? "更新日历事件" : parts.joined(separator: "\n")
}

// MARK: - Reminder Skills ─────────────────────────────────────────────────────

struct ListReminderListsSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "list_reminder_lists",
        description: "List all macOS Reminders lists.",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        let lists = context.remindersService.getLists()
        guard !lists.isEmpty else { return SkillResult("没有找到提醒事项清单。") }
        let payload = SchedulePayload(lists: lists.map { ScheduleReminderListItem(id: $0.calendarIdentifier, title: $0.title) })
        return SkillResult(
            lists.map { "清单: \($0.title), ID: \($0.calendarIdentifier)" }.joined(separator: "\n"),
            payload: showUI ? payload : nil
        )
    }
}

struct ListRemindersSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "list_reminders",
        description: "Read active reminders. Do not include completed reminders unless the user explicitly asks for completed/history/done reminders.",
        parameters: agentObjectSchema(properties: tp([
            "list_name":         agentStringSchema("Optional reminders list name."),
            "query":             agentStringSchema("Optional text to search in reminder titles or notes."),
            "include_completed": agentBoolSchema("Set true only when the user explicitly asks for completed/history/done reminders.")
        ]))
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        let listName = agentStringArg(args, "list_name")
        let query    = agentStringArg(args, "query")?.lowercased()
        let wantsCompleted = (agentBoolArg(args, "include_completed") ?? false) && userExplicitlyAskedForCompleted(args)
        var reminders = await context.remindersService.getReminders(listName: listName, includeCompleted: wantsCompleted)
        if !wantsCompleted { reminders = reminders.filter { !$0.isCompleted } }
        if let query, !query.isEmpty {
            reminders = reminders.filter {
                ($0.title ?? "").lowercased().contains(query) ||
                ($0.notes ?? "").lowercased().contains(query)
            }
        }
        guard !reminders.isEmpty else { return SkillResult("没有找到匹配的提醒事项。") }
        let limited = reminders.prefix(80)
        let text    = limited.map(RemindersService.format).joined(separator: "\n\n")
        let payload = SchedulePayload(reminders: limited.map(RemindersService.snapshot).filter { wantsCompleted || !$0.isCompleted })
        let suffix  = reminders.count > 80 ? "\n\n仅返回前 80 条，请用 query 或 list_name 缩小范围。" : ""
        return SkillResult(text + suffix, payload: showUI ? payload : nil)
    }

    private func userExplicitlyAskedForCompleted(_ args: [String: Any]) -> Bool {
        let text = [agentStringArg(args, "query"), agentStringArg(args, "list_name")]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        return ["已完成", "完成的", "完成项", "历史", "done", "completed", "finished"]
            .contains { text.contains($0) }
    }
}

struct CreateReminderSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "create_reminder",
        description: "Create a reminder in macOS Reminders.",
        parameters: agentObjectSchema(properties: tp([
            "title":     agentStringSchema("Reminder title."),
            "due_date":  agentStringSchema("Optional ISO-8601 due date, for example 2026-04-27T18:00:00+08:00."),
            "notes":     agentStringSchema("Optional notes."),
            "list_name": agentStringSchema("Optional exact reminders list name.")
        ]), required: ["title"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        guard let title = agentStringArg(args, "title"), !title.isEmpty else { return .error("错误: 缺少 title。") }
        do {
            let dueDate = try agentParseDate(agentStringArg(args, "due_date"))
            let notes = agentStringArg(args, "notes")
            let listName = agentStringArg(args, "list_name")
            guard await context.confirmMutation(
                .createReminder,
                "新提醒事项：\(title)",
                createReminderSummaryText(dueDate: dueDate, notes: notes, listName: listName)
            ) else { return SkillResult("用户已取消创建提醒事项。") }
            let id = try context.remindersService.createReminder(
                title: title,
                dueDate: dueDate,
                notes: notes,
                listName: listName
            )
            var payload = SchedulePayload(actions: [ScheduleActionItem(kind: "created", title: "已创建", detail: title, reminderID: id)])
            if let reminder = context.remindersService.getReminder(id: id) {
                payload.reminders = [RemindersService.snapshot(reminder)]
            }
            return SkillResult("已创建提醒事项: \(title)\nID: \(id)", payload: payload)
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct UpdateReminderSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "update_reminder",
        description: "Update a reminder by ID.",
        parameters: agentObjectSchema(properties: tp([
            "id":             agentStringSchema("Reminder ID returned by list_reminders or create_reminder."),
            "title":          agentStringSchema("Optional new title."),
            "due_date":       agentStringSchema("Optional ISO-8601 due date."),
            "notes":          agentStringSchema("Optional new notes. Pass an empty string to clear notes."),
            "clear_due_date": agentBoolSchema("Set true to remove the due date.")
        ]), required: ["id"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        guard let id = agentStringArg(args, "id"), !id.isEmpty else { return .error("错误: 缺少 id。") }
        guard let current = context.remindersService.getReminder(id: id) else { return .error("错误: 找不到该提醒事项。") }
        do {
            let title        = agentStringArg(args, "title")
            let dueDate      = try agentParseDate(agentStringArg(args, "due_date"))
            let notes        = agentStringArg(args, "notes")
            let clearDueDate = agentBoolArg(args, "clear_due_date") ?? false
            guard await context.confirmMutation(
                .updateReminder,
                reminderSummaryText(current),
                updateReminderSummaryText(title: title, dueDate: dueDate, notes: notes, clearDueDate: clearDueDate)
            ) else { return SkillResult("用户已取消修改提醒事项。") }
            try context.remindersService.updateReminder(id: id, title: title, dueDate: dueDate, notes: notes, clearDueDate: clearDueDate)
            var payload = SchedulePayload(actions: [ScheduleActionItem(kind: "updated", title: "已更新", detail: id, reminderID: id)])
            if let r = context.remindersService.getReminder(id: id) { payload.reminders = [RemindersService.snapshot(r)] }
            return SkillResult("已更新提醒事项。\nID: \(id)", payload: payload)
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct CompleteReminderSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "complete_reminder",
        description: "Mark a reminder complete by ID.",
        parameters: agentObjectSchema(properties: tp([
            "id": agentStringSchema("Reminder ID returned by list_reminders or create_reminder.")
        ]), required: ["id"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        guard let id = agentStringArg(args, "id"), !id.isEmpty else { return .error("错误: 缺少 id。") }
        guard let current = context.remindersService.getReminder(id: id) else { return .error("错误: 找不到该提醒事项。") }
        do {
            guard await context.confirmMutation(.completeReminder, reminderSummaryText(current), "标记为已完成") else {
                return SkillResult("用户已取消完成提醒事项。")
            }
            try context.remindersService.completeReminder(id: id)
            var payload = SchedulePayload(actions: [ScheduleActionItem(kind: "completed", title: "已完成", detail: id, reminderID: id)])
            if let r = context.remindersService.getReminder(id: id) { payload.reminders = [RemindersService.snapshot(r)] }
            return SkillResult("已完成提醒事项。\nID: \(id)", payload: payload)
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct DeleteReminderSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "delete_reminder",
        description: "Delete a reminder by ID.",
        parameters: agentObjectSchema(properties: tp([
            "id": agentStringSchema("Reminder ID returned by list_reminders or create_reminder.")
        ]), required: ["id"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasRemindersAccess else { return .error("错误: 尚未授权访问提醒事项。") }
        guard let id = agentStringArg(args, "id"), !id.isEmpty else { return .error("错误: 缺少 id。") }
        guard let current = context.remindersService.getReminder(id: id) else { return .error("错误: 找不到该提醒事项。") }
        do {
            guard await context.confirmMutation(.deleteReminder, reminderSummaryText(current), "删除后将从 Reminders 中移除") else {
                return SkillResult("用户已取消删除提醒事项。")
            }
            try context.remindersService.deleteReminder(id: id)
            return SkillResult("已删除提醒事项。\nID: \(id)",
                               payload: SchedulePayload(actions: [ScheduleActionItem(kind: "deleted", title: "已删除", detail: id)]))
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

// MARK: - Course Skills ────────────────────────────────────────────────────────

struct ListCoursesSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "list_courses",
        description: "Read the app-local imported course schedule only when the user explicitly asks about courses/class timetable, names a specific course, or mentions class changes such as 调课/停课/补课/换教室/上课安排. Do not call this for generic exams, deadlines, meetings, events, or notifications. Courses are not system Calendar events. Defaults to the next 14 days when no date range is provided.",
        parameters: agentObjectSchema(properties: tp([
            "start_date": agentStringSchema("Optional ISO-8601 range start. Defaults to now."),
            "end_date":   agentStringSchema("Optional ISO-8601 range end. Defaults to 14 days after start_date."),
            "query":      agentStringSchema("Optional text to search in course title, location, or notes.")
        ]))
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        do {
            let start = try agentParseDate(agentStringArg(args, "start_date")) ?? Date()
            let end   = try agentParseDate(agentStringArg(args, "end_date"))
                ?? Calendar.current.date(byAdding: .day, value: 14, to: start)
                ?? start.addingTimeInterval(14 * 24 * 60 * 60)
            let query = agentStringArg(args, "query")?.lowercased()
            let courses = context.localCourses(startDate: start, endDate: end, query: query)
                .sorted { $0.startDate < $1.startDate }
            guard !courses.isEmpty else { return SkillResult("没有找到匹配的本地课程。") }
            let visible = Array(courses.prefix(120))
            let suffix  = courses.count > 120 ? "\n\n仅返回前 120 条，请缩小日期范围或 query。" : ""
            return SkillResult(
                visible.map(formatCourseText).joined(separator: "\n\n") + suffix,
                payload: showUI ? SchedulePayload(courses: visible) : nil
            )
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

// MARK: - Calendar Skills ─────────────────────────────────────────────────────

struct ListCalendarsSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "list_calendars",
        description: "List all writable/readable macOS Calendar calendars.",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasCalendarAccess else { return .error("错误: 尚未授权访问日历。") }
        let calendars = context.remindersService.getEventCalendars()
        guard !calendars.isEmpty else { return SkillResult("没有找到日历。") }
        let payload = SchedulePayload(calendars: calendars.map { ScheduleCalendarItem(id: $0.calendarIdentifier, title: $0.title) })
        return SkillResult(
            calendars.map { "日历: \($0.title), ID: \($0.calendarIdentifier)" }.joined(separator: "\n"),
            payload: showUI ? payload : nil
        )
    }
}

struct ListCalendarEventsSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "list_calendar_events",
        description: "Read macOS Calendar events by date range, calendar name, and optional text query.",
        parameters: agentObjectSchema(properties: tp([
            "calendar_name": agentStringSchema("Optional calendar name."),
            "start_date":    agentStringSchema("Optional ISO-8601 range start. Defaults to now."),
            "end_date":      agentStringSchema("Optional ISO-8601 range end. Defaults to 14 days after start_date."),
            "query":         agentStringSchema("Optional text to search in event title, notes, or location.")
        ]))
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasCalendarAccess else { return .error("错误: 尚未授权访问日历。") }
        do {
            let start        = try agentParseDate(agentStringArg(args, "start_date")) ?? Date()
            let end          = try agentParseDate(agentStringArg(args, "end_date"))
                ?? Calendar.current.date(byAdding: .day, value: 14, to: start)
                ?? start.addingTimeInterval(14 * 24 * 60 * 60)
            let calendarName = agentStringArg(args, "calendar_name")
            let query        = agentStringArg(args, "query")?.lowercased()
            var events = context.remindersService.getEvents(calendarName: calendarName, startDate: start, endDate: end)
                .filter { !context.isLegacyImportedCourse($0) }
            if let query, !query.isEmpty {
                events = events.filter {
                    ($0.title ?? "").lowercased().contains(query) ||
                    ($0.notes ?? "").lowercased().contains(query) ||
                    ($0.location ?? "").lowercased().contains(query)
                }
            }
            events.sort { $0.startDate < $1.startDate }
            guard !events.isEmpty else { return SkillResult("没有找到匹配的日历事件。") }
            let visible = events.prefix(80)
            let suffix  = events.count > 80 ? "\n\n仅返回前 80 条，请缩小日期范围或 query。" : ""
            return SkillResult(
                visible.map(formatEventText).joined(separator: "\n\n") + suffix,
                payload: showUI ? SchedulePayload(events: visible.map(RemindersService.snapshot)) : nil
            )
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct CreateCalendarEventSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "create_calendar_event",
        description: "Create a Calendar event.",
        parameters: agentObjectSchema(properties: tp([
            "title":         agentStringSchema("Event title."),
            "start_date":    agentStringSchema("ISO-8601 event start."),
            "end_date":      agentStringSchema("Optional ISO-8601 event end. Defaults to one hour after start_date."),
            "notes":         agentStringSchema("Optional notes."),
            "location":      agentStringSchema("Optional location."),
            "calendar_name": agentStringSchema("Optional exact calendar name."),
            "all_day":       agentBoolSchema("Whether this is an all-day event.")
        ]), required: ["title", "start_date"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasCalendarAccess else { return .error("错误: 尚未授权访问日历。") }
        guard let title = agentStringArg(args, "title"), !title.isEmpty else { return .error("错误: 缺少 title。") }
        do {
            guard let start = try agentParseDate(agentStringArg(args, "start_date")) else { return .error("错误: 缺少 start_date。") }
            let end = try agentParseDate(agentStringArg(args, "end_date")) ?? start.addingTimeInterval(3600)
            let notes = agentStringArg(args, "notes")
            let location = agentStringArg(args, "location")
            let calendarName = agentStringArg(args, "calendar_name")
            let isAllDay = agentBoolArg(args, "all_day") ?? false
            guard await context.confirmMutation(
                .createEvent,
                "新日历事件：\(title)",
                createEventSummaryText(startDate: start, endDate: end, notes: notes, location: location, calendarName: calendarName, isAllDay: isAllDay)
            ) else { return SkillResult("用户已取消创建日历事件。") }
            let id  = try context.remindersService.createEvent(
                title: title, startDate: start, endDate: end,
                notes: notes,
                location: location,
                calendarName: calendarName,
                isAllDay: isAllDay
            )
            var payload = SchedulePayload(actions: [ScheduleActionItem(kind: "created", title: "已创建日历事件", detail: title, calendarEventID: id)])
            if let event = context.remindersService.getEvent(id: id) { payload.events = [RemindersService.snapshot(event)] }
            return SkillResult("已创建日历事件: \(title)\nID: \(id)", payload: payload)
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct UpdateCalendarEventSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "update_calendar_event",
        description: "Update a Calendar event by ID. Requires app-side confirmation.",
        parameters: agentObjectSchema(properties: tp([
            "id":         agentStringSchema("Calendar event ID returned by list_calendar_events or create_calendar_event."),
            "title":      agentStringSchema("Optional new title."),
            "start_date": agentStringSchema("Optional ISO-8601 event start."),
            "end_date":   agentStringSchema("Optional ISO-8601 event end."),
            "notes":      agentStringSchema("Optional new notes. Pass empty string to clear notes."),
            "location":   agentStringSchema("Optional new location. Pass empty string to clear location.")
        ]), required: ["id"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasCalendarAccess else { return .error("错误: 尚未授权访问日历。") }
        guard let id = agentStringArg(args, "id"), !id.isEmpty else { return .error("错误: 缺少 id。") }
        guard let current = context.remindersService.getEvent(id: id) else { return .error("错误: 找不到该日历事件。") }
        do {
            let title    = agentStringArg(args, "title")
            let start    = try agentParseDate(agentStringArg(args, "start_date"))
            let end      = try agentParseDate(agentStringArg(args, "end_date"))
            let notes    = agentStringArg(args, "notes")
            let location = agentStringArg(args, "location")
            guard await context.confirmMutation(
                .updateEvent,
                eventSummaryText(current),
                updateEventSummaryText(title: title, startDate: start, endDate: end, notes: notes, location: location)
            ) else { return SkillResult("用户已取消修改日历事件。") }
            try context.remindersService.updateEvent(
                id: id, title: title, startDate: start, endDate: end, notes: notes, location: location,
                clearNotes: notes == "", clearLocation: location == ""
            )
            var payload = SchedulePayload(actions: [ScheduleActionItem(kind: "updated", title: "已更新日历事件", detail: id, calendarEventID: id)])
            if let event = context.remindersService.getEvent(id: id) { payload.events = [RemindersService.snapshot(event)] }
            return SkillResult("已更新日历事件。\nID: \(id)", payload: payload)
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

struct DeleteCalendarEventSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "delete_calendar_event",
        description: "Delete a Calendar event by ID. Requires app-side confirmation.",
        parameters: agentObjectSchema(properties: tp([
            "id": agentStringSchema("Calendar event ID returned by list_calendar_events or create_calendar_event.")
        ]), required: ["id"])
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard context.hasCalendarAccess else { return .error("错误: 尚未授权访问日历。") }
        guard let id = agentStringArg(args, "id"), !id.isEmpty else { return .error("错误: 缺少 id。") }
        guard let current = context.remindersService.getEvent(id: id) else { return .error("错误: 找不到该日历事件。") }
        do {
            guard await context.confirmMutation(.deleteEvent, eventSummaryText(current), "删除后将从 Calendar 中移除") else {
                return SkillResult("用户已取消删除日历事件。")
            }
            try context.remindersService.deleteEvent(id: id)
            return SkillResult("已删除日历事件。\nID: \(id)",
                               payload: SchedulePayload(actions: [ScheduleActionItem(kind: "deleted", title: "已删除日历事件", detail: id)]))
        } catch { return .error("错误: \(error.localizedDescription)") }
    }
}

// MARK: - Chaoxing Skills ─────────────────────────────────────────────────────

struct GetChaoxingAssignmentsSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "get_chaoxing_assignments",
        description: "获取学习通未完成作业列表。返回标题、课程名、截止时间（相对格式）和提交状态。Use when the user asks about homework, 作业, 截止日期, or 学习通 task list.",
        parameters: agentObjectSchema(properties: tp([
            "urgency_filter": agentStringSchema("筛选紧迫度：today=今天截止, this_week=本周, overdue=已逾期, all=全部（默认）"),
            "include_submitted": agentBoolSchema("是否包含已提交作业，默认 false")
        ]))
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        let cx = ChaoxingService.shared
        guard cx.isLoggedIn else { return .error("未登录学习通。请先在设置中扫码登录学习通，然后重试。") }
        do {
            let now = context.now
            let urgency = agentStringArg(args, "urgency_filter") ?? "all"
            let includeSubmitted = agentBoolArg(args, "include_submitted") ?? false
            let all = try await cx.fetchAllPendingAssignments()
            let source = includeSubmitted ? all : all.filter { isUnfinished($0) }

            // Apply urgency filter
            let cal = Calendar.current
            let filtered: [ChaoxingAssignment]
            switch urgency {
            case "today":
                filtered = source.filter { a in
                    guard let d = a.dueDate else { return false }
                    return cal.isDate(d, inSameDayAs: now)
                }
            case "this_week":
                let weekEnd = cal.date(byAdding: .day, value: 7, to: now) ?? now
                filtered = source.filter { a in
                    guard let d = a.dueDate else { return false }
                    return d >= now && d <= weekEnd
                }
            case "overdue":
                filtered = source.filter { a in (a.dueDate ?? .distantFuture) < now }
            default: // "all"
                filtered = source
            }

            let visible = filtered.compactMap { item(from: $0) }
                .sorted { ($0.dueDate) < ($1.dueDate) }
            guard !visible.isEmpty else {
                return SkillResult("学习通：暂无符合条件的作业（urgency_filter=\(urgency)）。")
            }
            let lines = visible.map { a in
                "• [\(a.courseName)] \(a.title) — \(a.status)，\(agentFormatRelativeDeadline(a.dueDate, now: now))"
            }
            return SkillResult(
                "学习通作业（共 \(visible.count) 条）：\n\n" + lines.joined(separator: "\n"),
                payload: SchedulePayload(chaoxingAssignments: visible)
            )
        } catch { return .error("错误: \(error.localizedDescription)") }
    }

    private func isUnfinished(_ a: ChaoxingAssignment) -> Bool {
        let s = a.status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return true }
        if s == "0" || s.contains("未") || s.contains("待完成") || s.contains("待提交") { return true }
        if s == "1" { return false }
        return !["已提交","已完成","已做","待批阅","已批阅","批阅中","提交成功","已截止"].contains { s.contains($0) }
    }

    private func item(from a: ChaoxingAssignment) -> ScheduleChaoxingAssignmentItem? {
        guard let due = a.dueDate else { return nil }
        return ScheduleChaoxingAssignmentItem(
            id: "\(a.courseId)-\(a.id)", originalID: a.id, courseID: a.courseId,
            courseName: a.courseName, title: a.title, dueDate: due,
            status: a.status, type: a.type, remainingTime: a.remainingTime
        )
    }
}

// MARK: - get_chaoxing_messages

struct GetChaoxingMessagesSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "get_chaoxing_messages",
        description: "Read recent 学习通 (Chaoxing/超星) WebIM messages using the same login state as assignments. Returns decoded message text with conversation, sender, time, and type. Use this when the user asks about 学习通消息、通知、群聊消息、老师或课程群最近说了什么.",
        parameters: agentObjectSchema(properties: tp([
            "limit": agentIntSchema("Maximum number of recent decoded messages to return. Default 20, max 60.")
        ]))
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        let cx = ChaoxingService.shared
        guard cx.isLoggedIn else { return .error("错误: 未登录学习通。请先在设置中扫码登录学习通，然后重试。") }
        do {
            let limit = min(max(agentIntArg(args, "limit") ?? 20, 1), 60)
            let muted  = context.mutedChaoxingConversations.map { $0.lowercased() }
            let all    = try await cx.fetchRecentMessages(maxConversations: 12, perConversation: 20)
            let messages = muted.isEmpty ? all : all.filter {
                !muted.contains($0.conversationName.lowercased())
            }
            // Structural filter: remove system ACK/recall messages before exposing to LLM or UI.
            // Semantic quality filtering is left to the LLM agent.
            let noiseTypes: Set<String> = ["READ_ACK", "DELIVER_ACK", "RECALL"]
            let visible = Array(messages.filter { !noiseTypes.contains($0.type) }.prefix(limit))
            guard !visible.isEmpty else { return SkillResult("学习通消息：最近没有可读取的文本消息。") }
            let lines = visible.map { message -> String in
                let chatLabel = message.isGroup ? "群聊" : "私聊"
                // Show human-readable sender name when available
                let senderLabel = message.senderName ?? message.senderID
                return "• [\(agentFormatDate(message.sentAt))][\(chatLabel):\(message.conversationName)][发送者:\(senderLabel)][\(message.type)] \(message.text)"
            }
            let payloadItems = visible.map { message in
                ScheduleChaoxingMessageInsightItem(
                    id: "chaoxing-message-\(message.id)",
                    sourceMessageID: message.id,
                    conversationID: message.conversationID,
                    conversationName: message.conversationName,
                    senderID: message.senderID,
                    senderName: message.senderName,
                    title: message.conversationName,
                    summary: compactChaoxingMessageText(message.text, limit: 180),
                    reason: "最近学习通消息",
                    actionHint: nil,
                    importance: "raw",
                    sentAt: message.sentAt,
                    extractedAt: Date(),
                    sourceTextPreview: compactChaoxingMessageText(message.text, limit: 220)
                )
            }
            return SkillResult(
                "学习通最近消息（共 \(visible.count) 条）：\n\n" + lines.joined(separator: "\n"),
                payload: showUI ? SchedulePayload(chaoxingMessages: payloadItems) : nil
            )
        } catch {
            return .error("错误: \(error.localizedDescription)")
        }
    }
}

private func compactChaoxingMessageText(_ text: String, limit: Int) -> String {
    let normalized = text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }
    return String(normalized.prefix(limit)) + "…"
}

struct DiagnoseChaoxingSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "diagnose_chaoxing",
        description: "Debug tool: show raw Chaoxing cookie and API response info. Use when assignments return empty or login seems broken.",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        SkillResult(await ChaoxingService.shared.diagnose())
    }
}

struct DiagnoseChaoxingIMSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "diagnose_chaoxing_im",
        description: "Debug tool: dump all raw fields from the Chaoxing IM conversation list and sample raw message bytes from each conversation. Use to understand how the 收件箱 or system notification channel differs from regular group chats.",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        SkillResult(await ChaoxingService.shared.diagnoseIM())
    }
}

struct DiagnoseChaoxingInboxSkill: ScheduleSkill {
    let tool = AgentTool(
        name: "diagnose_chaoxing_inbox",
        description: "Debug tool: probe multiple candidate Chaoxing inbox/notice REST API endpoints and dump raw HTTP status + response bodies. Also shows the IM conversation list with chatType for every entry including skipped ones. Use when 收件箱 messages are not appearing.",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        SkillResult(await ChaoxingService.shared.diagnoseInbox())
    }
}

// MARK: - read_message_memory

struct ReadMessageMemorySkill: ScheduleSkill {
    let tool = AgentTool(
        name: "read_message_memory",
        description: "读取学习通消息记忆文件中已提炼的重要信息。返回 JSON 字符串。当用户询问学习通消息摘要、最近通知、调课信息时，优先调用此工具（节省网络请求）。",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        let json = context.readMessageMemory()
        if json.isEmpty || json == "{}" || json == "[]" {
            return SkillResult("学习通消息记忆文件为空，暂无历史重要信息。")
        }
        return SkillResult("学习通消息记忆：\n" + json)
    }
}

// MARK: - refresh_message_memory

struct RefreshMessageMemorySkill: ScheduleSkill {
    let tool = AgentTool(
        name: "refresh_message_memory",
        description: "触发学习通 Memory Agent 拉取近期消息、去重作业通知、更新记忆。仅当现有 memory 不足、过期、用户明确追问最新学习通通知/调课/考试时使用。",
        parameters: agentObjectSchema(properties: tp())
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        SkillResult(await context.refreshMessageMemory())
    }
}

// MARK: - write_message_memory

struct WriteMessageMemorySkill: ScheduleSkill {
    var tool: AgentTool {
        AgentTool(
            name: "write_message_memory",
            description: "更新学习通消息记忆文件。传入完整的新 JSON 内容（保留已有重要条目 + 添加新条目，專1内容删除无用条目）。无需用户确认。",
            parameters: agentObjectSchema(
                properties: [
                    "memory_json": agentStringSchema(
                        "完整的 memory JSON 内容，格式与现有文件一致（schema_version, updated_at, entries[]）。最多 100 条。"
                    )
                ],
                required: ["memory_json"]
            )
        )
    }

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard let json = agentStringArg(args, "memory_json"), !json.isEmpty else {
            return .error("错误: 缺少 memory_json 参数。")
        }
        // Validate it's parseable JSON
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["entries"] != nil else {
            return .error("错误: memory_json 格式不正确，必须包含 entries 字段。")
        }
        let success = await context.writeMessageMemory(json)
        return success
            ? SkillResult("记忆文件已更新。")
            : .error("错误: 记忆文件写入失败。")
    }
}

// MARK: - delete_message_memory

struct DeleteMessageMemorySkill: ScheduleSkill {
    let tool = AgentTool(
        name: "delete_message_memory",
        description: "从学习通消息记忆中删除一条特定的记忆。当用户认为某条提取的记忆不重要或不需要再显示时使用。需要传入记忆的 id。",
        parameters: agentObjectSchema(
            properties: [
                "id": agentStringSchema("要删除的记忆条目的 id（通常是一个 UUID 字符串）")
            ],
            required: ["id"]
        )
    )

    func run(args: [String: Any], showUI: Bool, context: SkillContext) async -> SkillResult {
        guard let id = agentStringArg(args, "id"), !id.isEmpty else {
            return .error("错误: 缺少 id 参数。")
        }
        
        let jsonStr = context.readMessageMemory()
        guard !jsonStr.isEmpty, let data = jsonStr.data(using: .utf8),
              var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = parsed["entries"] as? [[String: Any]] else {
            return .error("错误: 无法读取或解析记忆文件。")
        }
        
        let initialCount = entries.count
        entries.removeAll { ($0["id"] as? String) == id }
        
        if entries.count == initialCount {
            return SkillResult("未找到指定 id 的记忆条目。")
        }
        
        parsed["entries"] = entries
        parsed["updated_at"] = ISO8601DateFormatter().string(from: context.now)
        
        guard let newData = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let newJsonStr = String(data: newData, encoding: .utf8) else {
            return .error("错误: 无法序列化新的记忆文件。")
        }
        
        let success = await context.writeMessageMemory(newJsonStr)
        return success ? SkillResult("已成功删除记忆条目 (ID: \(id))。") : .error("错误: 写入记忆文件失败。")
    }
}
