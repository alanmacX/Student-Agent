import CryptoKit
import Foundation

enum ChaoxingMessageFilter {
    private static let noiseTypes: Set<String> = ["READ_ACK", "DELIVER_ACK", "RECALL"]
    private static let shortChatter: Set<String> = [
        "好", "好的", "收到", "收到了", "ok", "OK", "嗯", "嗯嗯", "是", "不是",
        "谢谢", "辛苦了", "+1", "晚安", "哈哈", "强强", "666"
    ]

    static func run(messages: [ChaoxingMessage],
                    syncState: ChaoxingSyncState,
                    assignments: [ChaoxingAssignmentSnapshot],
                    mutedConversationNames: Set<String>,
                    now: Date = Date()) -> ChaoxingFilterResult {
        let normalized = messages
            .map(normalize)
            .sorted { $0.sentAt < $1.sentAt }

        let muted = mutedConversationNames.map { $0.lowercased() }
        var candidates: [ChaoxingCandidateMessage] = []
        var processedSourceIDs = Set<String>()
        var processedFingerprints = Set<String>()
        var droppedReasons: [String: String] = [:]
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let bootstrapCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let isBootstrap = syncState.initializedAt == nil

        for message in normalized {
            let dropReason: String?
            if syncState.processedSourceIDs.contains(message.sourceID) ||
                syncState.processedFingerprints.contains(message.fingerprint) {
                dropReason = "already_processed"
            } else if !muted.isEmpty && muted.contains(message.conversationName.lowercased()) {
                dropReason = "muted_conversation"
            } else if noiseTypes.contains(message.type) {
                dropReason = "noise_type"
            } else if message.text.isEmpty && message.imageURLs.isEmpty {
                dropReason = "empty_message"
            } else if isBootstrap && message.sentAt < bootstrapCutoff && !containsFutureCue(message.text) {
                dropReason = "bootstrap_old_without_future_cue"
            } else if message.sentAt < cutoff && !containsFutureCue(message.text) {
                dropReason = "stale_without_future_cue"
            } else if isPureChatter(message.text) {
                dropReason = "pure_chatter"
            } else if duplicateAssignmentNotice(message, assignments: assignments) {
                dropReason = "duplicate_assignment_notice"
            } else {
                dropReason = nil
            }

            if let dropReason {
                processedSourceIDs.insert(message.sourceID)
                processedFingerprints.insert(message.fingerprint)
                droppedReasons[message.sourceID] = dropReason
            } else {
                candidates.append(ChaoxingCandidateMessage(normalized: message, reason: "new_candidate"))
            }
        }

        return ChaoxingFilterResult(
            candidates: Array(candidates.suffix(40)),
            processedSourceIDs: processedSourceIDs,
            processedFingerprints: processedFingerprints,
            droppedReasons: droppedReasons
        )
    }

    static func normalize(_ message: ChaoxingMessage) -> ChaoxingNormalizedMessage {
        let text = ChaoxingTextNormalizer.displayText(message.text)
        let fingerprintBase = [
            message.conversationID,
            message.senderID,
            String(Int(message.sentAt.timeIntervalSince1970 / 60)),
            ChaoxingTextNormalizer.keyText(text),
            (message.imageURLs ?? []).joined(separator: ",")
        ].joined(separator: "|")
        return ChaoxingNormalizedMessage(
            rawMessage: message,
            sourceID: message.id,
            fingerprint: stableHash(fingerprintBase),
            conversationID: message.conversationID,
            conversationName: ChaoxingTextNormalizer.displayText(message.conversationName),
            isGroup: message.isGroup,
            senderID: message.senderID.isEmpty ? "unknown" : message.senderID,
            senderName: message.senderName,
            sentAt: message.sentAt,
            type: message.type,
            text: text,
            normalizedText: ChaoxingTextNormalizer.keyText(text),
            imageURLs: message.imageURLs ?? []
        )
    }

    private static func duplicateAssignmentNotice(_ message: ChaoxingNormalizedMessage,
                                                  assignments: [ChaoxingAssignmentSnapshot]) -> Bool {
        guard !assignments.isEmpty else { return false }
        let text = message.normalizedText
        guard text.contains("作业") || text.contains("任务") || text.contains("截止") || text.contains("ddl") else {
            return false
        }
        return assignments.contains { assignment in
            let title = ChaoxingTextNormalizer.keyText(assignment.title)
            let course = ChaoxingTextNormalizer.keyText(assignment.courseName)
            guard !title.isEmpty, text.contains(title) else { return false }
            return course.isEmpty || text.contains(course) || message.normalizedText.contains(course)
        }
    }

    private static func isPureChatter(_ text: String) -> Bool {
        let normalized = ChaoxingTextNormalizer.displayText(text)
        if normalized.isEmpty { return true }
        if shortChatter.contains(normalized) { return true }
        if normalized.count <= 3 && !containsFutureCue(normalized) { return true }
        return false
    }

    private static func containsFutureCue(_ text: String) -> Bool {
        let cues = ["今天", "明天", "后天", "本周", "下周", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "截止", "考试", "上课", "调课", "停课", "补课", "教室", "DDL", "ddl"]
        return cues.contains { text.contains($0) } || text.range(of: #"\d{1,2}[月/-]\d{1,2}"#, options: .regularExpression) != nil
    }

    private static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
