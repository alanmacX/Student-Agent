import Foundation
import SwiftUI
import EventKit

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
