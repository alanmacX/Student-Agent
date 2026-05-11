import CryptoKit
import Foundation

enum ChaoxingMemoryReducer {
    static func reduce(memory: ChaoxingMemoryDocument,
                       extracted: [ChaoxingExtractedInsight],
                       candidateMessages: [ChaoxingCandidateMessage],
                       assignmentKeys: Set<String>,
                       now: Date = Date()) -> ChaoxingMemoryDocument {
        let messageByID = Dictionary(uniqueKeysWithValues: candidateMessages.map { ($0.normalized.sourceID, $0.normalized) })
        var byKey = Dictionary(uniqueKeysWithValues: memory.entries.map { ($0.dedupeKey, $0) })

        for item in extracted {
            let decision = item.decision.lowercased()
            guard decision == "keep" else { continue }
            let confidence = item.confidence ?? 0.75
            guard confidence >= 0.55 else { continue }

            let sourceMessages = item.sourceIDs.compactMap { messageByID[$0] }
            guard !sourceMessages.isEmpty else { continue }
            if let linked = item.linkedAssignmentKey, assignmentKeys.contains(linked) {
                continue
            }
            let importance = normalizeImportance(item.importance)
            guard importance == "high" || importance == "medium" else { continue }

            let summary = ChaoxingTextNormalizer.displayText(item.summary ?? "")
            guard !summary.isEmpty else { continue }
            let title = ChaoxingTextNormalizer.displayText(item.title ?? sourceMessages.first?.conversationName ?? "学习通通知")
            let dedupeKey = canonicalDedupeKey(item: item, title: title, summary: summary, messages: sourceMessages)
            let expiresAt = item.expiresAt ?? defaultExpiry(for: item, messages: sourceMessages, now: now)
            guard expiresAt > now else { continue }

            var entry = byKey[dedupeKey] ?? ChaoxingMemoryEntry(
                id: UUID().uuidString,
                dedupeKey: dedupeKey,
                category: item.category ?? "notice",
                importance: importance,
                title: title.isEmpty ? "学习通通知" : title,
                summary: summary,
                reason: ChaoxingTextNormalizer.displayText(item.reason ?? "Memory Agent extracted actionable information."),
                actionHint: item.actionHint.map { ChaoxingTextNormalizer.displayText($0) },
                contentTime: item.contentTime,
                expiresAt: expiresAt,
                sourceIDs: [],
                sourceFingerprints: [],
                conversationIDs: [],
                conversationNames: [],
                senderNames: [],
                linkedAssignmentKey: item.linkedAssignmentKey,
                linkedCourseKey: item.linkedCourseKey,
                confidence: confidence,
                createdAt: now,
                updatedAt: now,
                sourceTextPreview: ""
            )

            entry.category = item.category ?? entry.category
            entry.importance = importance
            entry.title = title.isEmpty ? entry.title : title
            entry.summary = summary
            entry.reason = ChaoxingTextNormalizer.displayText(item.reason ?? entry.reason)
            entry.actionHint = item.actionHint.map { ChaoxingTextNormalizer.displayText($0) } ?? entry.actionHint
            entry.contentTime = item.contentTime ?? entry.contentTime
            entry.expiresAt = max(entry.expiresAt, expiresAt)
            entry.linkedAssignmentKey = item.linkedAssignmentKey ?? entry.linkedAssignmentKey
            entry.linkedCourseKey = item.linkedCourseKey ?? entry.linkedCourseKey
            entry.confidence = max(entry.confidence, confidence)
            entry.updatedAt = now
            entry.sourceIDs = merged(entry.sourceIDs, sourceMessages.map(\.sourceID))
            entry.sourceFingerprints = merged(entry.sourceFingerprints, sourceMessages.map(\.fingerprint))
            entry.conversationIDs = merged(entry.conversationIDs, sourceMessages.map(\.conversationID))
            entry.conversationNames = merged(entry.conversationNames, sourceMessages.map(\.conversationName))
            entry.senderNames = merged(entry.senderNames, sourceMessages.compactMap(\.senderName))
            entry.sourceTextPreview = ChaoxingTextNormalizer.preview(sourceMessages.map(\.text).joined(separator: " "), limit: 220)
            byKey[dedupeKey] = entry
        }

        let entries = byKey.values
            .filter { $0.expiresAt > now }
            .sorted(by: sortEntries)
        return ChaoxingMemoryDocument(
            schemaVersion: 2,
            updatedAt: now,
            entries: Array(entries.prefix(100))
        )
    }

    static func insights(from memory: ChaoxingMemoryDocument,
                         now: Date = Date(),
                         limit: Int = 40) -> [ScheduleChaoxingMessageInsightItem] {
        memory.entries
            .filter { $0.expiresAt > now }
            .sorted(by: sortEntries)
            .prefix(limit)
            .map { entry in
                ScheduleChaoxingMessageInsightItem(
                    id: "mem-\(entry.id)",
                    sourceMessageID: entry.sourceIDs.first ?? "",
                    conversationID: entry.conversationIDs.first ?? "memory",
                    conversationName: entry.conversationNames.first ?? "学习通",
                    senderID: "memory",
                    senderName: entry.senderNames.first,
                    title: entry.title,
                    summary: ChaoxingTextNormalizer.preview(entry.summary, limit: 180),
                    reason: ChaoxingTextNormalizer.preview(entry.reason, limit: 120),
                    actionHint: entry.actionHint.map { ChaoxingTextNormalizer.preview($0, limit: 120) },
                    importance: entry.importance,
                    sentAt: entry.contentTime ?? entry.updatedAt,
                    extractedAt: entry.updatedAt,
                    sourceTextPreview: ChaoxingTextNormalizer.preview(entry.sourceTextPreview.isEmpty ? entry.summary : entry.sourceTextPreview, limit: 220)
                )
            }
    }

    static func sortEntries(_ lhs: ChaoxingMemoryEntry, _ rhs: ChaoxingMemoryEntry) -> Bool {
        let li = lhs.importance == "high" ? 2 : (lhs.importance == "medium" ? 1 : 0)
        let ri = rhs.importance == "high" ? 2 : (rhs.importance == "medium" ? 1 : 0)
        if li != ri { return li > ri }
        let lt = lhs.contentTime ?? lhs.updatedAt
        let rt = rhs.contentTime ?? rhs.updatedAt
        return lt < rt
    }

    static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalDedupeKey(item: ChaoxingExtractedInsight,
                                           title: String,
                                           summary: String,
                                           messages: [ChaoxingNormalizedMessage]) -> String {
        if let explicit = item.dedupeKey, !explicit.isEmpty {
            return "llm::\(ChaoxingTextNormalizer.keyText(explicit))"
        }
        if let linked = item.linkedCourseKey, !linked.isEmpty {
            return "course::\(ChaoxingTextNormalizer.keyText(linked))::\(ChaoxingTextNormalizer.keyText(title))"
        }
        let base = [
            item.category ?? "notice",
            messages.first?.conversationName ?? "",
            title,
            summary
        ].joined(separator: "|")
        return "event::\(stableHash(ChaoxingTextNormalizer.keyText(base)))"
    }

    private static func defaultExpiry(for item: ChaoxingExtractedInsight,
                                      messages: [ChaoxingNormalizedMessage],
                                      now: Date) -> Date {
        if let contentTime = item.contentTime, contentTime > now {
            return contentTime.addingTimeInterval(12 * 60 * 60)
        }
        let sentAt = messages.map(\.sentAt).max() ?? now
        return sentAt.addingTimeInterval(14 * 24 * 60 * 60)
    }

    private static func normalizeImportance(_ value: String?) -> String {
        let lower = (value ?? "medium").lowercased()
        if lower == "high" || lower == "medium" || lower == "low" { return lower }
        return "medium"
    }

    private static func merged(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set(lhs)
        var result = lhs
        for value in rhs where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
