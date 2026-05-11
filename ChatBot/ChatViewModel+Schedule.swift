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
        let todayCourses = courseSchedule.filter { eventIntersects($0, today) }.sorted { $0.startDate < $1.startDate }
        let todayAssignments = assignments.filter { $0.dueDate >= now && today.contains($0.dueDate) }.sorted { $0.dueDate < $1.dueDate }
        let dueReminders = reminders.filter { r in r.dueDate.map { $0 >= now && today.contains($0) } ?? false }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let todayEvents = events.filter { eventIntersects($0, today) }
        let importantReminders = dueReminders.filter(isImportantReminder)
        let importantEvents = todayEvents.filter(isImportantEvent)
        let memoryHighlights = todayMemoryHighlights(now: now)
        let courseWarnings = courseMemoryWarningInsights(now: now)
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        let upcomingEvents7 = events.filter { $0.startDate >= tomorrow && $0.startDate <= weekEnd }.sorted { $0.startDate < $1.startDate }
        let upcomingReminders7 = reminders.filter { r in r.dueDate.map { $0 >= tomorrow && $0 <= weekEnd } ?? false }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let attentionItems = buildTodayAttentionItems(assignments: assignments, reminders: reminders, events: events, courses: upcomingCourses, memoryHighlights: memoryHighlights, courseWarnings: courseWarnings, now: now)

        let source = TodayWidgetSummarySource(attentionItems: attentionItems, todayAssignments: todayAssignments, importantReminders: importantReminders, importantEvents: importantEvents, todayDueReminders: dueReminders, todayEvents: todayEvents, todayCourses: todayCourses, allAssignments: assignments, allActiveReminders: reminders, allUpcomingEvents: events, allUpcomingCourses: upcomingCourses, memoryHighlights: memoryHighlights, courseWarnings: courseWarnings, quickCaptures: Array(quickCaptures.prefix(20)), recentConversationMessages: [], recentScheduleMessages: [])
        let nextHash = hashTodayWidgetSource(source)
        let oldSummary = todayWidget.sourceHash == nextHash ? todayWidget.summary : fallbackTodayWidgetSummary(source)
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
            guard !key.isEmpty else { todayWidget.summary = fallbackTodayWidgetSummary(source); saveTodayWidgetSnapshot(); return }
            do {
                let response = try await agentComplete(messages: [AgentMsg(role: .system, content: "你是一个极简日程助理。请基于结构化注意力清单，总结未来约 48 小时最值得关注的事务，不超过 120 字。越近越重要：逾期/今天最高，明天次之，后天只在重要时提。用户的日历事件和提醒事项拥有高优先级，学习通 DDL、调课、考试也很重要。不得凭空新增事项。重要规则：1. 标题含“（班）”或“(班)”表示调休补班/工作日标记，不表示今天是该节日。2. 对于语义重点（Insight），如果其文本提到的具体时间点已经过去（例如现在 14:30，文本提到 12:00 截止），除非是重要的逾期未完成任务，否则应视作已完成或已失效，不要在总结中提及。3. 不要列清单，不要 Markdown，不要寒暄。"), AgentMsg(role: .user, content: todayWidgetSummaryPrompt(source))], tools: [], provider: provider, model: economicalModel(for: provider), apiKey: key)
                let summary = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                guard !Task.isCancelled, todayWidget.sourceHash == sourceHash else { return }
                todayWidget.summary = summary.isEmpty ? fallbackTodayWidgetSummary(source) : summary
                todayWidget.generatedAt = Date()
                saveTodayWidgetSnapshot()
                refreshCompanionState(reason: "today-summary")
            } catch {
                guard !Task.isCancelled, todayWidget.sourceHash == sourceHash else { return }
                todayWidget.summary = fallbackTodayWidgetSummary(source); saveTodayWidgetSnapshot(); refreshCompanionState(reason: "today-summary-fallback")
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
        items += courses.filter { $0.endDate >= now && $0.startDate <= backgroundEnd }.map { TodayAttentionItem(id: "course:\($0.id)", kind: "course", title: $0.title, detail: "课程 · \(formatRelativeScheduleDate($0.startDate, now: now))", date: $0.startDate, score: todayAttentionScore(date: $0.startDate, now: now, sourceWeight: 10, keywordText: [$0.title, $0.notes ?? ""].joined(separator: " ")), horizon: eventIntersects($0, dayInterval(containing: now)) ? "primary" : ($0.startDate <= horizonEnd ? "upcoming" : "background")) }
        items += (memoryHighlights + courseWarnings).prefix(10).filter { !isItemSemanticallyExpired($0, now: now) }.map { i in
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
    private func formatRelativeScheduleDate(_ date: Date, now: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天 \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))" }
        if Calendar.current.isDateInTomorrow(date) { return "明天 \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))" }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "zh_CN"); fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Prompt Formatting

    private func todayWidgetSummaryPrompt(_ source: TodayWidgetSummarySource) -> String {
        let cal = Calendar.current, refToday = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: refToday)!, weekEnd = cal.date(byAdding: .day, value: 7, to: refToday)!
        let upA = source.allAssignments.filter { $0.dueDate >= tomorrow && $0.dueDate <= weekEnd }.prefix(8).map(formatChaoxingAssignmentForTodayWidget)
        let upR = source.allActiveReminders.filter { r in r.dueDate.map { $0 >= tomorrow && $0 <= weekEnd } ?? false }.prefix(6).map(formatReminderForTodayWidget)
        var sections: [String] = []
        sections.append("注意力清单（已按48小时衰减排序）：\n" + (source.attentionItems.isEmpty ? "无" : source.attentionItems.prefix(10).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("现在/今天最该注意：\n" + (source.attentionItems.filter { $0.horizon == "primary" }.prefix(5).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("未来48小时：\n" + (source.attentionItems.filter { $0.horizon == "upcoming" }.prefix(6).map(formatAttentionItemForTodayWidget).joined(separator: "\n")))
        sections.append("今日课程：\n" + (source.todayCourses.isEmpty ? "无" : source.todayCourses.map(formatEventForTodayWidget).joined(separator: "\n")))
        sections.append("今日日历事件：\n" + (source.todayEvents.isEmpty ? "无" : source.todayEvents.map(formatEventForTodayWidget).joined(separator: "\n")))
        sections.append("学习通 memory 重点：\n" + (source.memoryHighlights.isEmpty ? "无" : source.memoryHighlights.map(formatMemoryInsightForTodayWidget).joined(separator: "\n")))
        return "今天日期：\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))。请浓缩今日事务，48小时内优先。\n\n" + sections.joined(separator: "\n\n")
    }

    private func fallbackTodayWidgetSummary(_ source: TodayWidgetSummarySource) -> String {
        if let first = source.attentionItems.first { return "\(first.title) 是当前优先事项。" }
        return source.todayAssignments.isEmpty && source.todayDueReminders.isEmpty ? "今天暂时没有明确事务。" : "今天主要关注事务已在侧边栏列出。"
    }

    private func hashTodayWidgetSource(_ source: TodayWidgetSummarySource) -> String {
        guard let data = try? JSONEncoder().encode(source) else { return UUID().uuidString }
        var versioned = Data("today-widget-v4-48h-attention\n".utf8); versioned.append(data)
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

    private func finishScheduleTask(_ taskID: UUID?) {
        guard taskID == nil || scheduleTaskID == taskID else { return }
        isScheduleAgentRunning = false; scheduleTask = nil; scheduleTaskID = nil
    }
}
