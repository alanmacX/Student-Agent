import Foundation

@MainActor
struct ChaoxingMemoryAgent {
    var store: ChaoxingMemoryStore

    func process(messages: [ChaoxingMessage],
                 assignments: [ScheduleChaoxingAssignmentItem],
                 courses: [ScheduleCalendarEventItem],
                 mutedConversationNames: Set<String>,
                 provider: Provider,
                 model: String,
                 apiKey: String,
                 now: Date = Date()) async -> ChaoxingPipelineResult {
        var memory = store.readMemory(now: now)
        var sync = store.readSyncState()
        let assignmentSnapshot = ChaoxingAssignmentSnapshot.build(from: assignments)
        let assignmentKeys = Set(assignmentSnapshot.map(\.key))
        let assignmentHash = ChaoxingMemoryReducer.stableHash(assignmentSnapshot.map(\.key).sorted().joined(separator: "|"))

        if sync.initializedAt == nil {
            sync.processedSourceIDs.formUnion(memory.entries.flatMap(\.sourceIDs))
            sync.processedFingerprints.formUnion(memory.entries.flatMap(\.sourceFingerprints))
        }

        let filter = ChaoxingMessageFilter.run(
            messages: messages,
            syncState: sync,
            assignments: assignmentSnapshot,
            mutedConversationNames: mutedConversationNames,
            now: now
        )

        var processedSourceIDs = filter.processedSourceIDs
        var processedFingerprints = filter.processedFingerprints
        var candidateMessages = filter.candidates
        let originalCandidateFingerprints = Set(candidateMessages.map(\.normalized.fingerprint))

        if !candidateMessages.isEmpty {
            let enriched = await OCRService.enrichMessagesWithOCR(candidateMessages.map(\.normalized.rawMessage))
            let reasonByID = Dictionary(uniqueKeysWithValues: candidateMessages.map { ($0.normalized.sourceID, $0.reason) })
            candidateMessages = enriched.map {
                ChaoxingCandidateMessage(
                    normalized: ChaoxingMessageFilter.normalize($0),
                    reason: reasonByID[$0.id] ?? "new_candidate"
                )
            }
        }

        var extracted: [ChaoxingExtractedInsight] = []
        var llmSucceeded = false
        if !candidateMessages.isEmpty && !apiKey.isEmpty {
            if let envelope = await extractWithLLM(
                candidates: candidateMessages,
                assignments: assignmentSnapshot,
                courses: courses,
                activeMemory: memory,
                provider: provider,
                model: model,
                apiKey: apiKey,
                now: now
            ) {
                extracted = envelope.insights
                llmSucceeded = true
                processedSourceIDs.formUnion(candidateMessages.map(\.normalized.sourceID))
                processedFingerprints.formUnion(candidateMessages.map(\.normalized.fingerprint))
                processedFingerprints.formUnion(originalCandidateFingerprints)
            }
        }

        if llmSucceeded {
            memory = ChaoxingMemoryReducer.reduce(
                memory: memory,
                extracted: extracted,
                candidateMessages: candidateMessages,
                assignmentKeys: assignmentKeys,
                now: now
            )
            try? store.writeMemory(memory)
        } else {
            memory = store.sweep(document: memory, now: now)
            try? store.writeMemory(memory)
        }

        if sync.initializedAt == nil {
            sync.initializedAt = now
        }
        sync.lastSuccessfulFetchAt = now
        sync.assignmentKeys = assignmentKeys
        sync.assignmentSnapshotHash = assignmentHash
        sync.processedSourceIDs.formUnion(processedSourceIDs)
        sync.processedFingerprints.formUnion(processedFingerprints)
        trimSyncState(&sync)
        for message in messages {
            let current = sync.conversations[message.conversationID]
            if current?.lastSeenSentAt == nil || (current?.lastSeenSentAt ?? .distantPast) <= message.sentAt {
                sync.conversations[message.conversationID] = ChaoxingConversationSyncState(
                    lastSeenSentAt: message.sentAt,
                    lastSeenMessageID: message.id,
                    seenCount: (current?.seenCount ?? 0) + 1
                )
            }
        }
        try? store.writeSyncState(sync)

        store.appendTrace([
            "at": ISO8601DateFormatter().string(from: now),
            "messages": messages.count,
            "candidates": candidateMessages.count,
            "llm_succeeded": llmSucceeded,
            "kept": memory.entries.count,
            "dropped": filter.droppedReasons
        ])

        return ChaoxingPipelineResult(
            memory: memory,
            syncState: sync,
            insights: ChaoxingMemoryReducer.insights(from: memory, now: now),
            processedSourceIDs: processedSourceIDs,
            processedFingerprints: processedFingerprints,
            candidateCount: candidateMessages.count,
            keptCount: extracted.filter { $0.decision.lowercased() == "keep" }.count
        )
    }

    private func extractWithLLM(candidates: [ChaoxingCandidateMessage],
                                assignments: [ChaoxingAssignmentSnapshot],
                                courses: [ScheduleCalendarEventItem],
                                activeMemory: ChaoxingMemoryDocument,
                                provider: Provider,
                                model: String,
                                apiKey: String,
                                now: Date) async -> ChaoxingExtractionEnvelope? {
        let messages = [
            AgentMsg(role: .system, content: systemPrompt(now: now)),
            AgentMsg(role: .user, content: userPayload(
                candidates: candidates,
                assignments: assignments,
                courses: courses,
                activeMemory: activeMemory,
                now: now
            ))
        ]
        guard let response = try? await agentComplete(
            messages: messages,
            tools: [],
            provider: provider,
            model: model,
            apiKey: apiKey
        ), let text = response.text else {
            return nil
        }
        return parseEnvelope(text)
    }

    private func systemPrompt(now: Date) -> String {
        """
        Current time: \(agentFormatCurrentTime(now))
        You are the Chaoxing Memory Agent extraction profile for a schedule/todo app.
        Return strict JSON only, no markdown.

        Schema:
        {
          "insights": [
            {
              "decision": "keep" | "drop",
              "source_ids": ["message id"],
              "category": "assignment" | "course_change" | "exam" | "meeting" | "notice" | "other",
              "importance": "high" | "medium" | "low",
              "title": "short title",
              "summary": "what happened, with concrete dates/times if present",
              "reason": "why this belongs in memory, or why it was dropped",
              "action_hint": "optional next action",
              "content_time": "ISO-8601 date if the event time is known",
              "expires_at": "ISO-8601 date, required for keep. IMPORTANT: For time-specific tasks (e.g. 'prepare by 12:00 today', 'meeting at 15:00'), set this to exactly that time point. DO NOT use the default 14-day expiry for ephemeral/deadline tasks.",
              "dedupe_key": "stable semantic key",
              "linked_assignment_key": "exact assignment key if this only duplicates an existing assignment",
              "linked_course_key": "course key if this affects a course",
              "confidence": 0.0
            }
          ]
        }

        Rules:
        - Emit one object per candidate message or per clearly merged event.
        - Drop pure chat, acknowledgements, vague system noise, and anything already represented by the assignment snapshot.
        - If a teacher announces homework and the same assignment is in the assignment snapshot, drop it with linked_assignment_key.
        - Keep course changes such as reschedule, cancellation, makeup class, room change, exam, meeting, and actionable notices.
        - For keep decisions, expires_at must be in the future. If no event time exists, use sent_at + 14 days.
        - Use existing memory to merge repeated notices. Prefer stable dedupe_key over source id.
        """
    }

    private func userPayload(candidates: [ChaoxingCandidateMessage],
                             assignments: [ChaoxingAssignmentSnapshot],
                             courses: [ScheduleCalendarEventItem],
                             activeMemory: ChaoxingMemoryDocument,
                             now: Date) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let candidatePayload = candidates.map { candidate -> [String: Any] in
            let message = candidate.normalized
            return [
                "source_id": message.sourceID,
                "fingerprint": message.fingerprint,
                "conversation_id": message.conversationID,
                "conversation_name": message.conversationName,
                "is_group": message.isGroup,
                "sender_id": message.senderID,
                "sender_name": message.senderName ?? "",
                "sent_at": ISO8601DateFormatter().string(from: message.sentAt),
                "type": message.type,
                "text": ChaoxingTextNormalizer.preview(message.text, limit: 900),
                "image_urls": message.imageURLs
            ]
        }

        let assignmentData = (try? encoder.encode(assignments)) ?? Data("[]".utf8)
        let memorySummary = activeMemory.entries.prefix(30).map { entry in
            [
                "dedupe_key": entry.dedupeKey,
                "title": entry.title,
                "summary": entry.summary,
                "expires_at": ISO8601DateFormatter().string(from: entry.expiresAt)
            ]
        }
        let courseLines = courses
            .filter { $0.endDate >= now }
            .prefix(40)
            .map { course in
                "- \(course.title) \(agentFormatDate(course.startDate))-\(agentFormatDate(course.endDate)) \(course.location ?? "")"
            }
            .joined(separator: "\n")

        return """
        Candidate messages:
        \(jsonString(candidatePayload))

        Assignment snapshot. Existing homework here is already tracked by the assignment system:
        \(String(data: assignmentData, encoding: .utf8) ?? "[]")

        Course schedule snapshot:
        \(courseLines.isEmpty ? "No local course data." : courseLines)

        Active memory summary:
        \(jsonString(memorySummary))
        """
    }

    private func parseEnvelope(_ text: String) -> ChaoxingExtractionEnvelope? {
        let trimmed = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("{") {
            candidate = trimmed
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start <= end {
            candidate = String(trimmed[start...end])
        } else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChaoxingExtractionEnvelope.self, from: Data(candidate.utf8))
    }

    private func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private func trimSyncState(_ state: inout ChaoxingSyncState) {
        if state.processedSourceIDs.count > 4_000 {
            state.processedSourceIDs = Set(state.processedSourceIDs.suffix(2_000))
        }
        if state.processedFingerprints.count > 4_000 {
            state.processedFingerprints = Set(state.processedFingerprints.suffix(2_000))
        }
    }
}
