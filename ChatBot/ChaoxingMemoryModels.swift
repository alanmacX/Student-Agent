import Foundation

struct ChaoxingMemoryDocument: Codable, Equatable {
    var schemaVersion: Int
    var updatedAt: Date
    var entries: [ChaoxingMemoryEntry]

    init(schemaVersion: Int = 2, updatedAt: Date = Date(), entries: [ChaoxingMemoryEntry] = []) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case entries
    }
}

struct ChaoxingMemoryEntry: Codable, Identifiable, Equatable {
    var id: String
    var dedupeKey: String
    var category: String
    var importance: String
    var title: String
    var summary: String
    var reason: String
    var actionHint: String?
    var contentTime: Date?
    var expiresAt: Date
    var sourceIDs: [String]
    var sourceFingerprints: [String]
    var conversationIDs: [String]
    var conversationNames: [String]
    var senderNames: [String]
    var linkedAssignmentKey: String?
    var linkedCourseKey: String?
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var sourceTextPreview: String

    enum CodingKeys: String, CodingKey {
        case id
        case dedupeKey = "dedupe_key"
        case category
        case importance
        case title
        case summary
        case reason
        case actionHint = "action_hint"
        case contentTime = "content_time"
        case expiresAt = "expires_at"
        case sourceIDs = "source_ids"
        case sourceFingerprints = "source_fingerprints"
        case conversationIDs = "conversation_ids"
        case conversationNames = "conversation_names"
        case senderNames = "sender_names"
        case linkedAssignmentKey = "linked_assignment_key"
        case linkedCourseKey = "linked_course_key"
        case confidence
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceTextPreview = "source_text_preview"
    }
}

struct ChaoxingSyncState: Codable, Equatable {
    var schemaVersion: Int
    var initializedAt: Date?
    var lastSuccessfulFetchAt: Date?
    var processedSourceIDs: Set<String>
    var processedFingerprints: Set<String>
    var assignmentKeys: Set<String>
    var assignmentSnapshotHash: String?
    var conversations: [String: ChaoxingConversationSyncState]

    init(schemaVersion: Int = 1,
         initializedAt: Date? = nil,
         lastSuccessfulFetchAt: Date? = nil,
         processedSourceIDs: Set<String> = [],
         processedFingerprints: Set<String> = [],
         assignmentKeys: Set<String> = [],
         assignmentSnapshotHash: String? = nil,
         conversations: [String: ChaoxingConversationSyncState] = [:]) {
        self.schemaVersion = schemaVersion
        self.initializedAt = initializedAt
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
        self.processedSourceIDs = processedSourceIDs
        self.processedFingerprints = processedFingerprints
        self.assignmentKeys = assignmentKeys
        self.assignmentSnapshotHash = assignmentSnapshotHash
        self.conversations = conversations
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case initializedAt = "initialized_at"
        case lastSuccessfulFetchAt = "last_successful_fetch_at"
        case processedSourceIDs = "processed_source_ids"
        case processedFingerprints = "processed_fingerprints"
        case assignmentKeys = "assignment_keys"
        case assignmentSnapshotHash = "assignment_snapshot_hash"
        case conversations
    }
}

struct ChaoxingConversationSyncState: Codable, Equatable {
    var lastSeenSentAt: Date?
    var lastSeenMessageID: String?
    var seenCount: Int

    enum CodingKeys: String, CodingKey {
        case lastSeenSentAt = "last_seen_sent_at"
        case lastSeenMessageID = "last_seen_message_id"
        case seenCount = "seen_count"
    }
}

struct ChaoxingAssignmentSnapshot: Codable, Equatable {
    var key: String
    var courseName: String
    var title: String
    var dueDate: Date
    var status: String

    static func build(from assignments: [ScheduleChaoxingAssignmentItem]) -> [ChaoxingAssignmentSnapshot] {
        assignments.map { assignment in
            ChaoxingAssignmentSnapshot(
                key: Self.key(courseName: assignment.courseName, title: assignment.title),
                courseName: assignment.courseName,
                title: assignment.title,
                dueDate: assignment.dueDate,
                status: assignment.status
            )
        }
    }

    static func key(courseName: String, title: String) -> String {
        [courseName, title]
            .map { ChaoxingTextNormalizer.keyText($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "::")
    }
}

struct ChaoxingNormalizedMessage: Equatable {
    var rawMessage: ChaoxingMessage
    var sourceID: String
    var fingerprint: String
    var conversationID: String
    var conversationName: String
    var isGroup: Bool
    var senderID: String
    var senderName: String?
    var sentAt: Date
    var type: String
    var text: String
    var normalizedText: String
    var imageURLs: [String]
}

struct ChaoxingCandidateMessage: Equatable {
    var normalized: ChaoxingNormalizedMessage
    var reason: String
}

struct ChaoxingFilterResult: Equatable {
    var candidates: [ChaoxingCandidateMessage]
    var processedSourceIDs: Set<String>
    var processedFingerprints: Set<String>
    var droppedReasons: [String: String]
}

struct ChaoxingExtractedInsight: Codable, Equatable {
    var decision: String
    var sourceIDs: [String]
    var category: String?
    var importance: String?
    var title: String?
    var summary: String?
    var reason: String?
    var actionHint: String?
    var contentTime: Date?
    var expiresAt: Date?
    var dedupeKey: String?
    var linkedAssignmentKey: String?
    var linkedCourseKey: String?
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case decision
        case sourceIDs = "source_ids"
        case category
        case importance
        case title
        case summary
        case reason
        case actionHint = "action_hint"
        case contentTime = "content_time"
        case expiresAt = "expires_at"
        case dedupeKey = "dedupe_key"
        case linkedAssignmentKey = "linked_assignment_key"
        case linkedCourseKey = "linked_course_key"
        case confidence
    }
}

struct ChaoxingExtractionEnvelope: Codable, Equatable {
    var insights: [ChaoxingExtractedInsight]
}

struct ChaoxingPipelineResult: Equatable {
    var memory: ChaoxingMemoryDocument
    var syncState: ChaoxingSyncState
    var insights: [ScheduleChaoxingMessageInsightItem]
    var processedSourceIDs: Set<String>
    var processedFingerprints: Set<String>
    var candidateCount: Int
    var keptCount: Int
}

enum ChaoxingTextNormalizer {
    static func displayText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func keyText(_ value: String) -> String {
        displayText(value)
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    static func preview(_ value: String, limit: Int) -> String {
        let normalized = displayText(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }
}
