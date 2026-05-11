import Foundation

struct ChaoxingMemoryStore {
    private let fileManager = FileManager.default

    var supportDirectory: URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatBot", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    var memoryURL: URL { supportDirectory.appendingPathComponent("chaoxing_memory.json") }
    var syncStateURL: URL { supportDirectory.appendingPathComponent("chaoxing_sync_state.json") }
    var debugTraceURL: URL { supportDirectory.appendingPathComponent("memory_debug_trace.jsonl") }

    func readMemory(now: Date = Date()) -> ChaoxingMemoryDocument {
        guard let data = try? Data(contentsOf: memoryURL), !data.isEmpty else {
            return ChaoxingMemoryDocument(updatedAt: now)
        }
        let decoder = jsonDecoder()
        if let document = try? decoder.decode(ChaoxingMemoryDocument.self, from: data) {
            return sweep(document: document, now: now)
        }
        if let migrated = migrateLegacyMemory(data: data, now: now) {
            let swept = sweep(document: migrated, now: now)
            try? writeMemory(swept)
            return swept
        }
        return ChaoxingMemoryDocument(updatedAt: now)
    }

    func writeMemory(_ document: ChaoxingMemoryDocument) throws {
        let data = try jsonEncoder().encode(document)
        try data.write(to: memoryURL, options: .atomic)
    }

    func readMemoryString(now: Date = Date()) -> String {
        let document = readMemory(now: now)
        guard let data = try? jsonEncoder().encode(document) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeMemoryString(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        let decoder = jsonDecoder()
        do {
            let document: ChaoxingMemoryDocument
            if let v2 = try? decoder.decode(ChaoxingMemoryDocument.self, from: data) {
                document = v2
            } else if let migrated = migrateLegacyMemory(data: data, now: Date()) {
                document = migrated
            } else {
                return false
            }
            try writeMemory(document)
            return true
        } catch {
            return false
        }
    }

    func readSyncState() -> ChaoxingSyncState {
        guard let data = try? Data(contentsOf: syncStateURL), !data.isEmpty else {
            return ChaoxingSyncState()
        }
        return (try? jsonDecoder().decode(ChaoxingSyncState.self, from: data)) ?? ChaoxingSyncState()
    }

    func writeSyncState(_ state: ChaoxingSyncState) throws {
        let data = try jsonEncoder().encode(state)
        try data.write(to: syncStateURL, options: .atomic)
    }

    func appendTrace(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let encoded = Data(line.utf8)
        if fileManager.fileExists(atPath: debugTraceURL.path),
           let handle = try? FileHandle(forWritingTo: debugTraceURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: encoded)
        } else {
            try? encoded.write(to: debugTraceURL, options: .atomic)
        }
    }

    @discardableResult
    func maintain(now: Date = Date()) -> ChaoxingMemoryDocument {
        let swept = sweep(document: readMemory(now: now), now: now)
        let compacted = compact(document: swept, now: now)
        try? writeMemory(compacted)
        return compacted
    }

    func sweep(document: ChaoxingMemoryDocument, now: Date = Date()) -> ChaoxingMemoryDocument {
        var copy = document
        copy.entries = copy.entries
            .filter { $0.expiresAt > now }
            .sorted(by: ChaoxingMemoryReducer.sortEntries)
        copy.updatedAt = now
        return copy
    }

    func physicalSweep(now: Date = Date()) {
        let document = readMemory(now: now)
        let swept = sweep(document: document, now: now)
        try? writeMemory(swept)
    }

    private func compact(document: ChaoxingMemoryDocument, now: Date) -> ChaoxingMemoryDocument {
        var byKey: [String: ChaoxingMemoryEntry] = [:]
        for entry in document.entries.sorted(by: ChaoxingMemoryReducer.sortEntries) {
            guard var existing = byKey[entry.dedupeKey] else {
                byKey[entry.dedupeKey] = entry
                continue
            }
            existing.importance = existing.importance == "high" || entry.importance == "low" ? existing.importance : entry.importance
            existing.summary = existing.summary.count >= entry.summary.count ? existing.summary : entry.summary
            existing.reason = existing.reason.isEmpty ? entry.reason : existing.reason
            existing.actionHint = existing.actionHint ?? entry.actionHint
            existing.contentTime = existing.contentTime ?? entry.contentTime
            existing.expiresAt = max(existing.expiresAt, entry.expiresAt)
            existing.sourceIDs = mergeUnique(existing.sourceIDs, entry.sourceIDs)
            existing.sourceFingerprints = mergeUnique(existing.sourceFingerprints, entry.sourceFingerprints)
            existing.conversationIDs = mergeUnique(existing.conversationIDs, entry.conversationIDs)
            existing.conversationNames = mergeUnique(existing.conversationNames, entry.conversationNames)
            existing.senderNames = mergeUnique(existing.senderNames, entry.senderNames)
            existing.confidence = max(existing.confidence, entry.confidence)
            existing.updatedAt = max(existing.updatedAt, entry.updatedAt)
            if existing.sourceTextPreview.isEmpty { existing.sourceTextPreview = entry.sourceTextPreview }
            byKey[entry.dedupeKey] = existing
        }
        return ChaoxingMemoryDocument(
            schemaVersion: 2,
            updatedAt: now,
            entries: Array(byKey.values.sorted(by: ChaoxingMemoryReducer.sortEntries).prefix(100))
        )
    }

    private func mergeUnique(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set(lhs)
        var result = lhs
        for value in rhs where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private func migrateLegacyMemory(data: Data, now: Date) -> ChaoxingMemoryDocument? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let migrated = entries.compactMap { entry -> ChaoxingMemoryEntry? in
            let summary = ChaoxingTextNormalizer.displayText(entry["summary"] as? String ?? "")
            guard !summary.isEmpty else { return nil }
            let id = entry["id"] as? String ?? UUID().uuidString
            let createdAt = (entry["created_at"] as? String).flatMap { iso.date(from: $0) } ?? now
            let expiresAt = (entry["expires_at"] as? String).flatMap { iso.date(from: $0) } ?? createdAt.addingTimeInterval(14 * 24 * 60 * 60)
            let title = ChaoxingTextNormalizer.displayText(entry["title"] as? String ?? "通知")
            let sourceID = entry["source_message_id"] as? String ?? ""
            let conversationName = ChaoxingTextNormalizer.displayText(entry["conversation_name"] as? String ?? "学习通")
            let dedupeBase = [conversationName, title, summary].joined(separator: "|")
            return ChaoxingMemoryEntry(
                id: id,
                dedupeKey: "legacy::\(ChaoxingMemoryReducer.stableHash(dedupeBase))",
                category: "notice",
                importance: entry["importance"] as? String ?? "medium",
                title: title.isEmpty ? "通知" : title,
                summary: summary,
                reason: "Migrated from v1 Chaoxing memory.",
                actionHint: entry["action_hint"] as? String,
                contentTime: nil,
                expiresAt: expiresAt,
                sourceIDs: sourceID.isEmpty ? [] : [sourceID],
                sourceFingerprints: [],
                conversationIDs: [],
                conversationNames: conversationName.isEmpty ? [] : [conversationName],
                senderNames: [],
                linkedAssignmentKey: nil,
                linkedCourseKey: nil,
                confidence: 0.8,
                createdAt: createdAt,
                updatedAt: now,
                sourceTextPreview: ChaoxingTextNormalizer.preview(summary, limit: 220)
            )
        }
        return ChaoxingMemoryDocument(schemaVersion: 2, updatedAt: now, entries: migrated)
    }

    private func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
