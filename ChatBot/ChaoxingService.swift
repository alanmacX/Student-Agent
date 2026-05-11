import Foundation
import AppKit
import CoreFoundation

// MARK: - Models

struct ChaoxingCourse: Identifiable, Codable, Equatable {
    var id: String        // courseId
    var name: String
    var teacherName: String
    var classId: String
    var cpi: String       // campus platform ID, needed for assignment API
}

struct ChaoxingAssignment: Identifiable, Codable, Equatable {
    var id: String
    var courseId: String
    var courseName: String
    var title: String
    var dueDate: Date?
    var status: String
    var type: String
    var remainingTime: String
}

struct ChaoxingMessageConversation: Identifiable, Codable, Equatable {
    var id: String
    var msgId: String
    var name: String
    var isGroup: Bool
    var updatedAt: Date?
    var avatarHTMLOrURL: String
}

struct ChaoxingMessage: Identifiable, Codable, Equatable {
    var id: String
    var conversationID: String
    var conversationName: String
    var isGroup: Bool
    var senderID: String
    /// Display name from fromUser.nickname in the raw IM JSON (not Protobuf).
    var senderName: String?
    var senderPuid: String?
    var sentAt: Date
    var type: String
    var text: String
    /// Remote image URLs extracted from IMAGE-type message content parts.
    /// Non-nil only when the message contains at least one image attachment.
    var imageURLs: [String]?
}

struct ChaoxingConversationProbe: Identifiable, Codable, Equatable {
    var id: String
    var msgId: String
    var name: String
    var isGroup: Bool
    var updatedAt: Date?
    var latestText: String

    var signature: String {
        "\(msgId)|\(Int(updatedAt?.timeIntervalSince1970 ?? 0))|\(latestText)"
    }
}

enum ChaoxingQRStatus {
    case waiting            // type 3 — not scanned yet
    case scanned            // type 4 — scanned, user sees confirm button on phone
    case confirmed          // status:true — login complete
    case expired            // c >= 50 or type 2 expired
    case error(String)
}

// MARK: - Service

@MainActor
final class ChaoxingService: ObservableObject {

    static let shared = ChaoxingService()

    @Published var isLoggedIn: Bool = false
    @Published var userName: String = ""

    private let baseURL = "https://passport2.chaoxing.com"
    private var cookieFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("chaoxing_cookies.json")
    }

    // Dedicated URLSession with automatic cookie handling
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: cfg)
    }()

    init() {
        restoreLoginCookiesToSharedStorage()
        if hasSavedCookies() {
            Task { await verifySession() }
        }
    }

    // MARK: - QR Login

    /// Step 1: Sets up session and returns UUID, enc, and QR image ready for display.
    func createQRSession() async throws -> (uuid: String, enc: String, qrImage: NSImage) {
        // Visit login page — sets JSESSIONID + route in shared cookie storage
        let loginURL = URL(string: "\(baseURL)/login")!
        _ = try await urlSession.data(for: request(loginURL))

        // Refresh QR to get fresh uuid + enc
        var refreshReq = request(URL(string: "\(baseURL)/refreshQRCode")!, referer: "\(baseURL)/login")
        refreshReq.httpMethod = "POST"
        refreshReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (refreshData, _) = try await urlSession.data(for: refreshReq)

        guard let json = try? JSONSerialization.jsonObject(with: refreshData) as? [String: Any],
              let uuid = json["uuid"] as? String,
              let enc  = json["enc"]  as? String else {
            throw CXError.badResponse
        }

        // Download QR PNG image (server-rendered)
        let imgURL = URL(string: "\(baseURL)/createqr?uuid=\(uuid)&fid=-1")!
        let (imgData, _) = try await urlSession.data(for: request(imgURL))
        guard let image = NSImage(data: imgData), image.isValid else { throw CXError.badResponse }

        return (uuid, enc, image)
    }

    /// Step 2: Poll for scan status. Call every 3 s.
    /// On .confirmed, auth cookies are captured automatically via shared cookie storage.
    func pollQR(uuid: String, enc: String) async throws -> ChaoxingQRStatus {
        var pollReq = request(URL(string: "\(baseURL)/getauthstatus/v2")!, referer: "\(baseURL)/login")
        pollReq.httpMethod = "POST"
        pollReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "uuid=\(uuid)&enc=\(enc)&doubleFactorLogin=0&forbidotherlogin=0"
        pollReq.httpBody = body.data(using: .utf8)

        let (data, _) = try await urlSession.data(for: pollReq)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .error("解析失败")
        }

        let statusOK = json["status"] as? Bool ?? false
        let type     = json["type"]   as? Int ?? -1

        if statusOK {
            // Login confirmed — follow the redirect to i.mooc.chaoxing.com to collect auth cookies
            try await finalizeLogin()
            return .confirmed
        }

        switch type {
        case 4:  return .scanned    // Phone scanned; waiting for user to tap Confirm
        case 6:  return .expired    // User cancelled on phone
        case 7:  return .expired    // Error / re-scan needed
        default: return .waiting    // type 3 = not yet scanned; others = still waiting
        }
    }

    // MARK: - Courses & Assignments

    func fetchCourses() async throws -> [ChaoxingCourse] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        let url = URL(string: "https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&mcode=&rss=1")!
        let (data, _) = try await urlSession.data(for: request(url, referer: "https://i.chaoxing.com", mobile: true))
        return parseCourses(data)
    }

    func fetchAssignments(courseId: String, classId: String, cpi: String, courseName: String) async throws -> [ChaoxingAssignment] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        // task-list returns HTML; requires mobile UA + X-Requested-With: com.chaoxing.mobile
        let urlStr = "https://mooc1-api.chaoxing.com/work/task-list?courseId=\(courseId)&classId=\(classId)&cpi=\(cpi)"
        guard let url = URL(string: urlStr) else { return [] }
        let req = request(url, referer: "https://mooc1.chaoxing.com", mobile: true)
        let (data, _) = try await urlSession.data(for: req)
        return parseAssignmentsFromHTML(data, courseId: courseId, courseName: courseName)
    }

    func fetchAllPendingAssignments() async throws -> [ChaoxingAssignment] {
        let courses = try await fetchCourses()
        var all: [ChaoxingAssignment] = []
        await withTaskGroup(of: [ChaoxingAssignment].self) { group in
            for course in courses {
                group.addTask {
                    (try? await self.fetchAssignments(
                        courseId: course.id,
                        classId: course.classId,
                        cpi: course.cpi,
                        courseName: course.name)) ?? []
                }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return all.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    // MARK: - Messages

    func fetchMessageConversations() async throws -> [ChaoxingMessageConversation] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        let params = try await fetchIMParams()
        return try await fetchMessageConversations(params: params)
    }

    func fetchRecentMessages(maxConversations: Int = 12, perConversation: Int = 20) async throws -> [ChaoxingMessage] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        let params = try await fetchIMParams()
        let conversations = try await fetchMessageConversations(params: params)
            .filter { !$0.id.isEmpty }
            .prefix(max(1, maxConversations))

        var messages: [ChaoxingMessage] = []
        var seenIDs = Set<String>()
        for conversation in conversations {
            // Use try? so a single bad conversation (e.g. inbox) never aborts the whole fetch.
            let batch = (try? await fetchRoamingMessages(
                params: params,
                conversation: conversation,
                limit: max(1, perConversation)
            )) ?? []
            for message in batch where seenIDs.insert(message.id).inserted {
                messages.append(message)
            }
        }

        // Merge inbox/notice messages (separate API, no Protobuf)
        let inboxMessages = (try? await fetchInboxNotices(limit: perConversation)) ?? []
        for message in inboxMessages where seenIDs.insert(message.id).inserted {
            messages.append(message)
        }

        return messages.sorted { $0.sentAt > $1.sentAt }
    }

    func fetchMessageConversationProbes(limit: Int = 12) async throws -> [ChaoxingConversationProbe] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        let params = try await fetchIMParams()
        let conversations = try await fetchMessageConversations(params: params)
            .filter { !$0.id.isEmpty }
            .prefix(max(1, limit))
        return conversations.map {
            ChaoxingConversationProbe(
                id: $0.id,
                msgId: $0.msgId,
                name: $0.name,
                isGroup: $0.isGroup,
                updatedAt: $0.updatedAt,
                latestText: ""
            )
        }
    }

    func fetchRecentMessages(forConversationIDs conversationIDs: Set<String>,
                             perConversation: Int = 20,
                             fallbackMaxConversations: Int = 12) async throws -> [ChaoxingMessage] {
        guard isLoggedIn else { throw CXError.notLoggedIn }
        guard !conversationIDs.isEmpty else { return [] }
        let params = try await fetchIMParams()
        let allConversations = try await fetchMessageConversations(params: params)
            .filter { !$0.id.isEmpty }
        let selected = allConversations.filter {
            conversationIDs.contains($0.id) || conversationIDs.contains($0.name)
        }
        let conversations = selected.isEmpty
            ? Array(allConversations.prefix(max(1, fallbackMaxConversations)))
            : selected

        var messages: [ChaoxingMessage] = []
        var seenIDs = Set<String>()
        for conversation in conversations {
            let batch = (try? await fetchRoamingMessages(
                params: params,
                conversation: conversation,
                limit: max(1, perConversation)
            )) ?? []
            for message in batch where seenIDs.insert(message.id).inserted {
                messages.append(message)
            }
        }
        let inboxMessages = (try? await fetchInboxNotices(limit: perConversation)) ?? []
        for message in inboxMessages where seenIDs.insert(message.id).inserted {
            messages.append(message)
        }
        return messages.sorted { $0.sentAt > $1.sentAt }
    }

    /// Fetch system / notification inbox messages from notice.chaoxing.com.
    /// Confirmed response structure (2026-05):
    ///   { "notices": { "list": [ { "idCode", "content", "createrName",
    ///                              "createrId", "insertTime" (ms), ... } ] } }
    private func fetchInboxNotices(limit: Int) async throws -> [ChaoxingMessage] {
        guard let url = URL(string: "https://notice.chaoxing.com/pc/notice/getNoticeList?pnum=1&count=\(limit)&type=0") else {
            throw CXError.badResponse
        }
        let (data, response) = try await urlSession.data(for: request(url, referer: "https://i.chaoxing.com"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CXError.badResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let noticesObj = json["notices"] as? [String: Any],
              let rawList = noticesObj["list"] as? [[String: Any]] else {
            return []
        }

        return rawList.compactMap { item -> ChaoxingMessage? in
            // Primary ID is "idCode" (hex string); fall back to numeric "id"
            let rawID = (item["idCode"] as? String) ?? str(item["id"] ?? "")
            guard !rawID.isEmpty else { return nil }

            // Build text: optional title + content
            let title   = (item["title"]   as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let content = (item["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text: String
            if !title.isEmpty && !content.isEmpty {
                text = "\(title)\n\(content)"
            } else if !content.isEmpty {
                text = content
            } else if !title.isEmpty {
                text = title
            } else {
                return nil
            }

            // Sender: "createrName" + "createrId" (confirmed field names)
            let senderName = (item["createrName"] as? String) ?? "系统通知"
            let senderUID  = str(item["createrId"] ?? item["createrPuid"] ?? "system")

            // Timestamp: "insertTime" in milliseconds (confirmed)
            let tsMillis = (item["insertTime"] as? NSNumber)
                        ?? (item["createTime"] as? NSNumber)
                        ?? (item["sendTime"]   as? NSNumber)
            let sentAt   = tsMillis.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()

            return ChaoxingMessage(
                id: "inbox-\(rawID)",
                conversationID: "inbox",
                conversationName: "收件箱",
                isGroup: false,
                senderID: senderUID,
                senderName: senderName,
                senderPuid: nil,
                sentAt: sentAt,
                type: "TEXT",
                text: text,
                imageURLs: nil
            )
        }
    }

    /// Diagnostic: probe multiple candidate inbox/notice API endpoints and dump raw responses.
    func diagnoseInbox() async -> String {
        guard isLoggedIn else { return "未登录学习通。" }
        var lines: [String] = ["=== Chaoxing 收件箱 API 诊断 ===\n"]

        // Candidate endpoints — try all, record status + first 800 chars of response body
        let candidates: [(label: String, url: String)] = [
            ("notice v1", "https://notice.chaoxing.com/pc/notice/getNoticeList?pnum=1&count=20&type=0"),
            ("notice v2", "https://notice.chaoxing.com/pc/notice/noticeList?pnum=1&count=20&type=0"),
            ("notice mobile", "https://notice.chaoxing.com/phone/notice/getNoticeList?pnum=1&count=20&type=0"),
            ("im inbox list", "https://im.chaoxing.com/webim/inbox/list?pageNum=1&pageSize=20"),
            ("im notice", "https://im.chaoxing.com/webim/message/getNoticeList?pageNum=1&pageSize=20"),
            ("XT notice", "https://xt.chaoxing.com/api/notification/list?page=1&pageSize=20"),
        ]

        for c in candidates {
            guard let url = URL(string: c.url) else {
                lines.append("[\(c.label)] 无效 URL"); continue
            }
            guard let (data, resp) = try? await urlSession.data(for: request(url, referer: "https://i.chaoxing.com")),
                  let http = resp as? HTTPURLResponse else {
                lines.append("[\(c.label)] 请求失败"); continue
            }
            let body = String(data: data, encoding: .utf8) ?? "(非UTF-8)"
            // For working endpoints (2xx), dump more of the response to see exact JSON structure
            let limit = (200..<300).contains(http.statusCode) ? 2000 : 300
            let preview = String(body.prefix(limit)).replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(c.label)] HTTP \(http.statusCode) → \(preview)")
        }

        // Also probe the IM conversation list to see raw chatType of inbox entry
        if let params = try? await fetchIMParams() {
            let url = URL(string: "https://im.chaoxing.com/webim/message/list/getMessageList")!
            var req = request(url, referer: "https://im.chaoxing.com/webim/me")
            req.httpMethod = "POST"
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(["tuid": params.tuid, "puid": params.puid, "token": params.token])
            if let (listData, _) = try? await urlSession.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {
                lines.append("\n=== IM 会话列表 (\(list.count) 条，含被过滤项) ===")
                // First 3 items: dump ALL keys (to discover real field names)
                for (i, item) in list.prefix(3).enumerated() {
                    lines.append("--- 会话[\(i)] 全字段 ---")
                    for key in item.keys.sorted() {
                        lines.append("  \(key): \(item[key] ?? "nil")")
                    }
                }
                // Remaining: summary only
                for (i, item) in list.dropFirst(3).enumerated() {
                    let chatType = item["chatType"] as? String ?? "(nil)"
                    let chatName = item["chatName"] as? String ?? "(nil)"
                    let chatId   = item["chatId"]   as? String ?? "(nil)"
                    lines.append("[\(i+3)] chatType=\(chatType) name=\(chatName) id=\(chatId)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Diagnostic: dump raw IM conversation list + sample raw messages from each conversation.
    /// This is the tool to understand how 收件箱 differs from normal group chats.
    func diagnoseIM() async -> String {
        guard isLoggedIn else { return "未登录学习通。" }
        var lines: [String] = ["=== Chaoxing IM 诊断 ===\n"]

        guard let params = try? await fetchIMParams() else {
            return "IM 参数获取失败（fetchIMParams 抛出错误）"
        }
        lines.append("tuid=\(params.tuid)  puid=\(params.puid)\n")

        // --- 1. Raw conversation list ---
        let url = URL(string: "https://im.chaoxing.com/webim/message/list/getMessageList")!
        var req = request(url, referer: "https://im.chaoxing.com/webim/me")
        req.httpMethod = "POST"
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(["tuid": params.tuid, "puid": params.puid, "token": params.token])

        guard let (listData, _) = try? await urlSession.data(for: req),
              let listJSON = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let list = listJSON["data"] as? [[String: Any]] else {
            return "会话列表接口失败"
        }

        lines.append("共 \(list.count) 条会话：\n")
        for (i, item) in list.enumerated() {
            lines.append("--- 会话 [\(i)] ---")
            // Dump every key
            let sorted = item.keys.sorted()
            for key in sorted {
                let val = item[key]
                lines.append("  \(key): \(val ?? "nil")")
            }

            // --- 2. Try fetching roaming messages for this conversation ---
            let chatId = str(item["chatId"] ?? "")
            guard !chatId.isEmpty else { continue }

            // Determine suffix: try both and report which works
            for suffix in ["@conference.easemob.com", "@easemob.com"] {
                let roamURL = URL(string: "https://a1-vip6.easecdn.com/cx-dev/cxstudy/users/\(params.tuid)/messageroaming")!
                var roamReq = URLRequest(url: roamURL)
                roamReq.httpMethod = "POST"
                roamReq.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
                roamReq.setValue("Bearer \(params.token)", forHTTPHeaderField: "Authorization")
                roamReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                guard let body = try? JSONSerialization.data(withJSONObject: ["queue": chatId + suffix, "start": -1, "end": -1]) else { continue }
                roamReq.httpBody = body

                guard let (roamData, _) = try? await urlSession.data(for: roamReq),
                      let roamJSON = try? JSONSerialization.jsonObject(with: roamData) as? [String: Any] else { continue }

                let statusStr = roamJSON["status"] as? String ?? roamJSON["code"] as? String ?? "?"
                let dataObj = roamJSON["data"] as? [String: Any]
                let msgs = dataObj?["msgs"] as? [[String: Any]] ?? []
                lines.append("  → queue=\(chatId)\(suffix) status=\(statusStr) msgs=\(msgs.count)")
                if !msgs.isEmpty {
                    // Show first 2 raw msg strings (truncated)
                    for (mi, rawMsg) in msgs.prefix(2).enumerated() {
                        if let encoded = rawMsg["msg"] as? String {
                            let preview = String(encoded.prefix(120))
                            lines.append("    msg[\(mi)] (base64, \(encoded.count)c): \(preview)…")
                        }
                        // Also dump other keys in rawMsg besides "msg"
                        let otherKeys = rawMsg.keys.filter { $0 != "msg" }.sorted()
                        if !otherKeys.isEmpty {
                            let kv = otherKeys.compactMap { k -> String? in
                                guard let v = rawMsg[k] else { return nil }
                                return "\(k)=\(v)"
                            }.joined(separator: " | ")
                            lines.append("    other keys: \(kv)")
                        }
                        let diagConversation = ChaoxingMessageConversation(
                            id: chatId,
                            msgId: str(item["msgId"] ?? ""),
                            name: decodedString(str(item["chatName"] ?? "学习通消息")),
                            isGroup: suffix == "@conference.easemob.com",
                            updatedAt: millisDate(item["updateTime"]) ?? millisDate(item["createTime"]),
                            avatarHTMLOrURL: str(item["chatIco"] ?? "")
                        )
                        if let decoded = decodeRawRoamingMessage(rawMsg, conversation: diagConversation, suffix: suffix) {
                            let sender = decoded.senderName ?? decoded.senderID
                            let preview = String(decoded.text.replacingOccurrences(of: "\n", with: " ").prefix(180))
                            lines.append("    decoded[\(mi)]: [\(decoded.isGroup ? "群聊" : "私聊"):\(decoded.conversationName)] sender=\(sender) type=\(decoded.type) text=\(preview)")
                        } else {
                            lines.append("    decoded[\(mi)]: 解析失败")
                        }
                    }
                    break  // found working suffix, no need to try the other
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Diagnostic: probe real API endpoints.
    func diagnose() async -> String {
        var lines: [String] = []

        // Fetch raw channel list — NO isFiled filter, ALL entries
        let url = URL(string: "https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&mcode=&rss=1")!
        guard let (data, _) = try? await urlSession.data(for: request(url, referer: "https://i.chaoxing.com", mobile: true)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelList = json["channelList"] as? [[String: Any]] else {
            return "获取课程列表失败"
        }

        var allCourses: [(id: String, classId: String, cpi: String, name: String)] = []
        for channel in channelList {
            guard channel["cataid"] as? String == "100000002",
                  let content = channel["content"] as? [String: Any] else { continue }
            let courseData = (content["course"] as? [String: Any])?["data"] as? [[String: Any]]
            let courseId = str(courseData?.first?["id"] ?? "")
            let classId  = str(channel["key"] ?? "")
            let cpi      = str(channel["cpi"] ?? "")
            guard !courseId.isEmpty, !classId.isEmpty else { continue }
            let name     = content["name"] as? String ?? "(未知)"
            let filed    = content["isFiled"] as? Int ?? 0
            allCourses.append((courseId, classId, cpi, "\(name)\(filed == 1 ? "[归档]" : "")"))
        }
        lines.append("全部课程（含归档）: \(allCourses.count) 门")

        // Parallel scan ALL courses
        var withWork: [(String, String)] = []
        await withTaskGroup(of: (String, String)?.self) { group in
            for c in allCourses {
                group.addTask {
                    let ep = "https://mooc1-api.chaoxing.com/work/task-list?courseId=\(c.id)&classId=\(c.classId)&cpi=\(c.cpi)"
                    guard let u = URL(string: ep),
                          let (d, _) = try? await self.urlSession.data(for: self.request(u, referer: "https://mooc1.chaoxing.com", mobile: true)),
                          let html = String(data: d, encoding: .utf8) else { return nil }
                    if html.contains("暂无作业") || html.contains("class=\"empty\"") { return nil }
                    let body = html.components(separatedBy: "<body>").last ?? html
                    return (c.name, String(body.prefix(500)).replacingOccurrences(of: "\n", with: " "))
                }
            }
            for await r in group { if let v = r { withWork.append(v) } }
        }

        lines.append("有作业内容的课程: \(withWork.count) 门")

        // Fetch full HTML of first course with content to see <li> structure
        if let (firstName, _) = withWork.first,
           let first = allCourses.first(where: { "\($0.name)\($0.id == $0.id ? "" : "")" == firstName || $0.name == firstName.replacingOccurrences(of: "[归档]", with: "") }) {
            let ep = "https://mooc1-api.chaoxing.com/work/task-list?courseId=\(first.id)&classId=\(first.classId)&cpi=\(first.cpi)"
            if let u = URL(string: ep),
               let (d, _) = try? await urlSession.data(for: request(u, referer: "https://mooc1.chaoxing.com", mobile: true)),
               let html = String(data: d, encoding: .utf8) {
                // Find the first <li> block
                if let liStart = html.range(of: "<li "),
                   let ulEnd = html.range(of: "</ul>") {
                    let section = String(html[liStart.lowerBound..<ulEnd.upperBound].prefix(3000))
                    lines.append("\n=== \(firstName) 作业列表 HTML ===\n\(section)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Session

    func logout() {
        isLoggedIn = false
        userName = ""
        try? FileManager.default.removeItem(at: cookieFileURL)
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] {
            if cookie.domain.contains("chaoxing") || cookie.domain.contains("mooc") {
                storage.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Private

    private func finalizeLogin() async throws {
        // Following this URL triggers the redirect chain that sets uid, _d, vc3, cx_p_token etc.
        let landingURL = URL(string: "http://i.mooc.chaoxing.com/space/index")!
        _ = try? await urlSession.data(for: request(landingURL))

        // Also hit the SSO verify endpoint so cookies propagate to chaoxing.com domain
        let ssoURL = URL(string: "https://sso.chaoxing.com/apis/login/userLogin4Uname.do")!
        let (data, _) = try await urlSession.data(for: request(ssoURL))

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? Bool, result {
            isLoggedIn = true
            if let msg = json["msg"] as? [String: Any], let name = msg["name"] as? String {
                userName = name
            }
            saveCurrentCookiesToFile()
        } else {
            // Even if SSO check fails, try to verify separately
            await verifySession()
        }
    }

    private func verifySession() async {
        let url = URL(string: "https://sso.chaoxing.com/apis/login/userLogin4Uname.do")!
        guard let (data, resp) = try? await urlSession.data(for: request(url)),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? Bool, result else {
            isLoggedIn = false; return
        }
        isLoggedIn = true
        if let msg = json["msg"] as? [String: Any], let name = msg["name"] as? String {
            userName = name
        }
    }

    // Mobile UA is required for mooc1-api.chaoxing.com — desktop UA returns "温馨提示" HTML
    private let mobileUA = "Mozilla/5.0 (Linux; Android 12; MI10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Mobile Safari/537.36 com.chaoxing.mobile/ChaoXingStudy_3_6.7.2_android_phone_10831_263"
    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private func request(_ url: URL, referer: String? = nil, mobile: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(mobile ? mobileUA : desktopUA, forHTTPHeaderField: "User-Agent")
        if mobile {
            req.setValue("com.chaoxing.mobile", forHTTPHeaderField: "X-Requested-With")
            req.setValue("zh_CN", forHTTPHeaderField: "Accept-Language")
        }
        if let ref = referer { req.setValue(ref, forHTTPHeaderField: "Referer") }
        return req
    }

    private struct ChaoxingIMParams {
        let tuid: String
        let puid: String
        let token: String
    }

    private func fetchIMParams() async throws -> ChaoxingIMParams {
        let url = URL(string: "https://im.chaoxing.com/webim/me")!
        let (data, _) = try await urlSession.data(for: request(url, referer: "https://i.chaoxing.com"))
        guard let html = String(data: data, encoding: .utf8),
              let tuid = firstHTMLValue(in: html, id: "myTuid"),
              let puid = firstHTMLValue(in: html, id: "myPuid"),
              let token = firstHTMLValue(in: html, id: "myToken"),
              !tuid.isEmpty, !puid.isEmpty, !token.isEmpty else {
            throw CXError.notLoggedIn
        }
        return ChaoxingIMParams(tuid: tuid, puid: puid, token: token)
    }

    private func fetchMessageConversations(params: ChaoxingIMParams) async throws -> [ChaoxingMessageConversation] {
        let url = URL(string: "https://im.chaoxing.com/webim/message/list/getMessageList")!
        var req = request(url, referer: "https://im.chaoxing.com/webim/me")
        req.httpMethod = "POST"
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "tuid": params.tuid,
            "puid": params.puid,
            "token": params.token
        ])

        let (data, _) = try await urlSession.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? String) == "success",
              let list = json["data"] as? [[String: Any]] else {
            throw CXError.badResponse
        }

        return list.compactMap { item -> ChaoxingMessageConversation? in
            guard String(describing: item["folder"] ?? "false") != "true" else { return nil }
            let id = str(item["chatId"] ?? "")
            guard !id.isEmpty else { return nil }
            // Use chatType field when available to distinguish group vs 1-to-1.
            // The API may omit chatType entirely (returns nil) — in that case default to
            // non-group; fetchRoamingMessages will try both suffixes as a fallback.
            let chatType = item["chatType"] as? String ?? ""
            let isGroup = chatType == "groupchat"
            let updatedAt = millisDate(item["updateTime"]) ?? millisDate(item["createTime"])
            return ChaoxingMessageConversation(
                id: id,
                msgId: str(item["msgId"] ?? ""),
                name: decodedString(str(item["chatName"] ?? "学习通消息")),
                isGroup: isGroup,
                updatedAt: updatedAt,
                avatarHTMLOrURL: str(item["chatIco"] ?? "")
            )
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private func fetchRoamingMessages(params: ChaoxingIMParams,
                                      conversation: ChaoxingMessageConversation,
                                      limit: Int) async throws -> [ChaoxingMessage] {
        let roamURL = URL(string: "https://a1-vip6.easecdn.com/cx-dev/cxstudy/users/\(params.tuid)/messageroaming")!

        // Try the expected suffix first; if it returns 0 messages, also try the other.
        // This handles the case where chatType is absent and isGroup may be wrong.
        let primarySuffix  = conversation.isGroup ? "@conference.easemob.com" : "@easemob.com"
        let fallbackSuffix = conversation.isGroup ? "@easemob.com" : "@conference.easemob.com"

        for suffix in [primarySuffix, fallbackSuffix] {
            var req = URLRequest(url: roamURL)
            req.httpMethod = "POST"
            req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
            req.setValue("Bearer \(params.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "queue": conversation.id + suffix,
                "start": -1,
                "end": -1
            ])

            guard let (data, _) = try? await urlSession.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObject = json["data"] as? [String: Any],
                  let rawMessages = dataObject["msgs"] as? [[String: Any]],
                  !rawMessages.isEmpty else { continue }

            let decoded = rawMessages.compactMap {
                decodeRawRoamingMessage($0, conversation: conversation, suffix: suffix)
            }
            if !decoded.isEmpty {
                return Array(decoded.sorted { $0.sentAt > $1.sentAt }.prefix(limit))
            }
        }
        return []
    }

    private func decodeRawRoamingMessage(
        _ raw: [String: Any],
        conversation: ChaoxingMessageConversation,
        suffix: String
    ) -> ChaoxingMessage? {
        guard let encoded = raw["msg"] as? String else { return nil }
        let fromUser = raw["fromUser"] as? [String: Any]
        let rawNickname = firstNonEmptyString([
            fromUser?["nickname"],
            fromUser?["name"],
            fromUser?["realName"],
            fromUser?["showName"],
            raw["fromName"],
            raw["fromNickName"]
        ]).map { decodedString($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let rawSenderUID = firstNonEmptyString([
            raw["from"],
            fromUser?["uid"],
            fromUser?["puid"],
            fromUser?["id"],
            raw["fromUid"],
            raw["fromPuid"]
        ])
        let rawMsgTime = (raw["msgTime"] as? NSNumber)?.doubleValue
        var effectiveConversation = conversation
        effectiveConversation.isGroup = suffix == "@conference.easemob.com"
        return decodeRoamingMessage(
            encoded,
            conversation: effectiveConversation,
            rawSenderUID: rawSenderUID,
            rawSenderName: rawNickname.flatMap { $0.isEmpty ? nil : $0 },
            rawMsgTimeMs: rawMsgTime
        )
    }

    private func firstHTMLValue(in html: String, id: String) -> String? {
        let pattern = #"id="\#(NSRegularExpression.escapedPattern(for: id))"[^>]*>([^<]*)"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = rx.firstMatch(in: html, range: range), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formBody(_ params: [String: String]) -> Data {
        params
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Parsing


    // Parse backclazzdata JSON — field paths confirmed from live API response:
    //   cataid "100000002" = course entry (skip folders/other cataid)
    //   classId  = channel["key"]
    //   cpi      = channel["cpi"]
    //   courseId = content.course.data[0].id
    //   name     = content.name
    private func parseCourses(_ data: Data) -> [ChaoxingCourse] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelList = json["channelList"] as? [[String: Any]] else { return [] }
        return channelList.compactMap { channel -> ChaoxingCourse? in
            // Only course entries; cataid "100000017" = folder, skip
            guard channel["cataid"] as? String == "100000002" else { return nil }
            guard let content = channel["content"] as? [String: Any] else { return nil }
            let courseData = (content["course"] as? [String: Any])?["data"] as? [[String: Any]]
            let courseId = str(courseData?.first?["id"] ?? "")
            let classId  = str(channel["key"] ?? "")
            let cpi      = str(channel["cpi"] ?? "")
            guard !courseId.isEmpty, !classId.isEmpty else { return nil }
            let teacher = courseData?.first?["teacherfactor"] as? String ?? ""
            let name    = content["name"] as? String ?? "(未知课程)"
            return ChaoxingCourse(id: courseId, name: name, teacherName: teacher, classId: classId, cpi: cpi)
        }
    }

    // Parse assignment list from task-list HTML.
    // Confirmed structure from live response:
    //   <li onclick="goTask(this);" data="..." data1="TASKREFID">
    //     <p>TITLE</p>
    //     <span>STATUS</span>          ← "待批阅" / "已完成" / "未完成" etc.
    //     <span class="fr">剩余Xh</span>  ← optional remaining time
    //   </li>
    private func parseAssignmentsFromHTML(_ data: Data, courseId: String, courseName: String) -> [ChaoxingAssignment] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        if html.contains("暂无作业") || html.contains("class=\"empty\"") { return [] }

        var assignments: [ChaoxingAssignment] = []
        let ns    = html as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Match each <li> block
        let liPat = #"<li onclick="goTask\(this\);"[^>]*data1="(\d+)"[^>]*>([\s\S]*?)</li>"#
        guard let liRx = try? NSRegularExpression(pattern: liPat, options: .dotMatchesLineSeparators) else { return [] }

        let titleRx  = try? NSRegularExpression(pattern: #"<p>([^<]+)</p>"#)
        // First plain <span> (no class) = status
        let statusRx = try? NSRegularExpression(pattern: #"<span>([^<]+)</span>"#)
        // <span class="fr"> = remaining time string
        let timeRx   = try? NSRegularExpression(pattern: #"<span class="fr">([^<]+)</span>"#)

        for m in liRx.matches(in: html, range: range) {
            guard m.numberOfRanges >= 3 else { continue }
            let id    = ns.substring(with: m.range(at: 1))
            let block = ns.substring(with: m.range(at: 2))
            let bns   = block as NSString
            let br    = NSRange(location: 0, length: bns.length)

            let title = titleRx?.firstMatch(in: block, range: br)
                .map { bns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "(作业)"
            let statusRaw = statusRx?.firstMatch(in: block, range: br)
                .map { bns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? ""
            let timeStr = timeRx?.firstMatch(in: block, range: br)
                .map { bns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? ""

            assignments.append(ChaoxingAssignment(
                id: id, courseId: courseId, courseName: courseName,
                title: title,
                dueDate: parseRelativeTimeString(timeStr),
                status: statusLabel(statusRaw),
                type: "作业",
                remainingTime: timeStr))
        }
        return assignments
    }

    // "剩余4小时46分钟" / "剩余2天3小时" → approximate absolute Date
    private func parseRelativeTimeString(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        if s.contains("已过期") || s.contains("已截止") || s.contains("已超时") { return Date() - 60 }
        var seconds: TimeInterval = 0
        let ns = s as NSString
        if let m = try? NSRegularExpression(pattern: #"(\d+)天"#).firstMatch(in: s, range: NSRange(location:0,length:ns.length)) {
            seconds += TimeInterval((ns.substring(with: m.range(at: 1)) as NSString).integerValue * 86400)
        }
        if let m = try? NSRegularExpression(pattern: #"(\d+)小时"#).firstMatch(in: s, range: NSRange(location:0,length:ns.length)) {
            seconds += TimeInterval((ns.substring(with: m.range(at: 1)) as NSString).integerValue * 3600)
        }
        if let m = try? NSRegularExpression(pattern: #"(\d+)分钟"#).firstMatch(in: s, range: NSRange(location:0,length:ns.length)) {
            seconds += TimeInterval((ns.substring(with: m.range(at: 1)) as NSString).integerValue * 60)
        }
        return seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }

    private func statusLabel(_ raw: String) -> String {
        switch raw {
        case "0", "未做": return "未提交"
        case "1", "已做": return "已提交"
        case "2", "已截止": return "已截止"
        default: return raw.isEmpty ? "未提交" : raw
        }
    }

    private func str(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private func firstNonEmptyString(_ values: [Any?]) -> String? {
        for value in values {
            let candidate = str(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Defensively decode possibly percent-encoded / HTML-escaped strings from Chaoxing IM.
    /// Returns the original string if decoding fails or is unnecessary.
    private func decodedString(_ raw: String) -> String {
        let percentDecoded = raw.removingPercentEncoding ?? raw
        return decodeHTMLEntities(percentDecoded)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let data = Data(raw.utf8)
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
        }
        return attributed.string
    }

    private func millisDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000) }
        if let string = value as? String, let double = Double(string) {
            return Date(timeIntervalSince1970: double / 1000)
        }
        return nil
    }

    private func decodeRoamingMessage(
        _ encoded: String,
        conversation: ChaoxingMessageConversation,
        rawSenderUID: String? = nil,
        rawSenderName: String? = nil,
        rawMsgTimeMs: Double? = nil
    ) -> ChaoxingMessage? {
        // --- Fast path: short non-Protobuf bodies (plain text like "OK") ---
        // If the string is short and not valid base64 Protobuf, treat it as plain text.
        let plainText: String? = {
            guard encoded.count < 256 else { return nil }
            // If we can't even base64-decode it, use raw string as text
            guard let data = Data(base64Encoded: encoded) else {
                let t = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            // If decoded bytes look like UTF-8 text (not binary Protobuf), use them
            if let t = String(data: data, encoding: .utf8), !t.isEmpty,
               t.allSatisfy({ !$0.isASCII || $0.asciiValue.map({ $0 >= 32 || [9,10,13].contains($0) }) ?? false }) {
                return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        // --- Normal Protobuf path ---
        guard let metaData = Data(base64Encoded: encoded),
              let meta = try? decodeMeta(metaData) else {
            // Fallback: if plain text detected above, synthesise a minimal message
            if let pt = plainText, let uid = rawSenderUID {
                let ts = rawMsgTimeMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? conversation.updatedAt ?? Date()
                return ChaoxingMessage(
                    id: "\(conversation.id)-\(Int(ts.timeIntervalSince1970 * 1000))-\(uid)",
                    conversationID: conversation.id, conversationName: conversation.name,
                    isGroup: conversation.isGroup, senderID: uid, senderName: rawSenderName,
                    senderPuid: nil, sentAt: ts, type: "TEXT", text: pt, imageURLs: nil
                )
            }
            return nil
        }

        let payloadData: Data
        if let payloadString = String(data: meta.payload, encoding: .utf8),
           let base64Payload = Data(base64Encoded: payloadString) {
            payloadData = base64Payload
        } else {
            payloadData = meta.payload
        }
        guard let body = try? decodeMessageBody(payloadData) else { return nil }
        let displayParts = body.contents
            .map(\.displayText)
            .map(decodedString)
            .filter { !$0.isEmpty }
        let text = displayParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Prefer Protobuf sender, then raw JSON uid
        let senderID = firstNonEmptyString([body.from?.name, meta.from?.name, rawSenderUID]) ?? "unknown"
        // Prefer raw JSON nickname (always human-readable) over Protobuf JID name
        let senderName = firstNonEmptyString([
            rawSenderName,
            body.ext["fromName"],
            body.ext["fromNickName"],
            body.ext["nickname"],
            body.ext["realName"]
        ]).map(decodedString)

        // Timestamp: Protobuf > raw JSON > conversation updatedAt
        let sentAt: Date
        if meta.timestamp > 0 {
            sentAt = Date(timeIntervalSince1970: TimeInterval(meta.timestamp) / 1000)
        } else if let ms = rawMsgTimeMs {
            sentAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            sentAt = conversation.updatedAt ?? Date()
        }

        let imageURLs: [String]? = {
            let paths = body.contents
                .filter { $0.rawType == 1 && !$0.remotePath.isEmpty }
                .map { $0.remotePath }
            return paths.isEmpty ? nil : paths
        }()
        return ChaoxingMessage(
            id: meta.id.isEmpty ? "\(conversation.id)-\(Int(meta.timestamp))-\(senderID)" : meta.id,
            conversationID: conversation.id,
            conversationName: conversation.name,
            isGroup: conversation.isGroup,
            senderID: senderID,
            senderName: senderName,
            senderPuid: body.ext["fromPuid"],
            sentAt: sentAt,
            type: messageTypeName(contents: body.contents, fallback: body.typeName),
            text: text,
            imageURLs: imageURLs
        )
    }

    private func messageTypeName(contents: [DecodedMessageContent], fallback: String) -> String {
        let meaningful = contents.filter { !$0.displayText.isEmpty }
        if meaningful.count == 1, let only = meaningful.first {
            return only.typeName
        }
        if meaningful.contains(where: { $0.rawType == 1 }) {
            return "MIXED_IMAGE"
        }
        return fallback
    }

    private struct DecodedMeta {
        var id = ""
        var from: DecodedJID?
        var timestamp: UInt64 = 0
        var payload = Data()
    }

    private struct DecodedJID {
        var name = ""
    }

    private struct DecodedMessageBody {
        var rawType: UInt64 = 0
        var from: DecodedJID?
        var contents: [DecodedMessageContent] = []
        var ext: [String: String] = [:]

        var typeName: String {
            switch rawType {
            case 1: return "CHAT"
            case 2: return "GROUPCHAT"
            case 3: return "CHATROOM"
            case 4: return "READ_ACK"
            case 5: return "DELIVER_ACK"
            case 6: return "RECALL"
            default: return "NORMAL"
            }
        }
    }

    private struct DecodedMessageContent {
        var rawType: UInt64 = 0
        var text = ""
        var displayName = ""
        var remotePath = ""
        var action = ""
        var customEvent = ""

        var typeName: String {
            switch rawType {
            case 1: return "IMAGE"
            case 2: return "VIDEO"
            case 3: return "LOCATION"
            case 4: return "VOICE"
            case 5: return "FILE"
            case 6: return "COMMAND"
            case 7: return "CUSTOM"
            default: return "TEXT"
            }
        }

        var displayText: String {
            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedText.isEmpty { return cleanedText }
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            switch rawType {
            case 1: return name.isEmpty ? "[图片]" : "[图片] \(name)"
            case 2: return name.isEmpty ? "[视频]" : "[视频] \(name)"
            case 4: return name.isEmpty ? "[语音]" : "[语音] \(name)"
            case 5: return name.isEmpty ? "[文件]" : "[文件] \(name)"
            case 6: return action.isEmpty ? "[命令消息]" : "[命令] \(action)"
            case 7: return customEvent.isEmpty ? "[自定义消息]" : "[自定义] \(customEvent)"
            default: return ""
            }
        }
    }

    private func decodeMeta(_ data: Data) throws -> DecodedMeta {
        var reader = ProtoReader(data)
        var meta = DecodedMeta()
        while let field = try reader.nextField() {
            switch field.number {
            case 1: meta.id = String(try reader.readVarint())
            case 2: meta.from = try decodeJID(try reader.readLengthDelimited())
            case 4: meta.timestamp = try reader.readVarint()
            case 6: meta.payload = try reader.readLengthDelimited()
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return meta
    }

    private func decodeJID(_ data: Data) throws -> DecodedJID {
        var reader = ProtoReader(data)
        var jid = DecodedJID()
        while let field = try reader.nextField() {
            switch field.number {
            case 2: jid.name = try reader.readString()
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return jid
    }

    private func decodeMessageBody(_ data: Data) throws -> DecodedMessageBody {
        var reader = ProtoReader(data)
        var body = DecodedMessageBody()
        while let field = try reader.nextField() {
            switch field.number {
            case 1: body.rawType = try reader.readVarint()
            case 2: body.from = try decodeJID(try reader.readLengthDelimited())
            case 4: body.contents.append(try decodeMessageContent(try reader.readLengthDelimited()))
            case 5:
                let kv = try decodeKeyValue(try reader.readLengthDelimited())
                if !kv.key.isEmpty, !kv.value.isEmpty { body.ext[kv.key] = kv.value }
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return body
    }

    private func decodeMessageContent(_ data: Data) throws -> DecodedMessageContent {
        var reader = ProtoReader(data)
        var content = DecodedMessageContent()
        while let field = try reader.nextField() {
            switch field.number {
            case 1: content.rawType = try reader.readVarint()
            case 2: content.text = decodedString(try reader.readString())
            case 6: content.displayName = decodedString(try reader.readString())
            case 7: content.remotePath = decodedString(try reader.readString())
            case 10: content.action = decodedString(try reader.readString())
            case 19: content.customEvent = decodedString(try reader.readString())
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return content
    }

    private func decodeKeyValue(_ data: Data) throws -> (key: String, value: String) {
        var reader = ProtoReader(data)
        var key = ""
        var value = ""
        while let field = try reader.nextField() {
            switch field.number {
            case 1: key = decodedString(try reader.readString())
            case 6: value = decodedString(try reader.readString())
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return (key, value)
    }

    private struct ProtoReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) {
            bytes = Array(data)
        }

        mutating func nextField() throws -> (number: Int, wireType: Int)? {
            guard index < bytes.count else { return nil }
            let key = try readVarint()
            return (Int(key >> 3), Int(key & 0x07))
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count && shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw CXError.badResponse
        }

        mutating func readLengthDelimited() throws -> Data {
            let length = Int(try readVarint())
            guard length >= 0, index + length <= bytes.count else { throw CXError.badResponse }
            let slice = bytes[index..<index + length]
            index += length
            return Data(slice)
        }

        mutating func readString() throws -> String {
            let data = try readLengthDelimited()
            return Self.decodeStringData(data)
        }

        private static func decodeStringData(_ data: Data) -> String {
            let encodings: [String.Encoding] = [
                .utf8,
                foundationEncoding(0x0632), // GB18030
                foundationEncoding(0x0631), // GBK
                foundationEncoding(0x0A03), // Big5
                .isoLatin1
            ]
            for encoding in encodings {
                if let text = String(data: data, encoding: encoding), !text.isEmpty {
                    return text
                }
            }
            return ""
        }

        private static func foundationEncoding(_ cfEncoding: UInt32) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding)))
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                guard index + 8 <= bytes.count else { throw CXError.badResponse }
                index += 8
            case 2:
                _ = try readLengthDelimited()
            case 5:
                guard index + 4 <= bytes.count else { throw CXError.badResponse }
                index += 4
            default:
                throw CXError.badResponse
            }
        }
    }

    // MARK: - Cookie persistence (file-based, no Keychain prompt)

    private func saveCurrentCookiesToFile() {
        let cxCookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.domain.contains("chaoxing") || $0.domain.contains("mooc") }
        guard let data = try? JSONEncoder().encode(cxCookies.map { CodableCookie($0) }) else { return }
        try? data.write(to: cookieFileURL, options: .atomic)
    }

    private func restoreLoginCookiesToSharedStorage() {
        guard let data = try? Data(contentsOf: cookieFileURL),
              let coded = try? JSONDecoder().decode([CodableCookie].self, from: data) else { return }
        let storage = HTTPCookieStorage.shared
        for cc in coded {
            if let cookie = cc.cookie { storage.setCookie(cookie) }
        }
    }

    private func hasSavedCookies() -> Bool {
        FileManager.default.fileExists(atPath: cookieFileURL.path)
    }
}

// MARK: - Codable cookie wrapper

private struct CodableCookie: Codable {
    let dict: [String: String]

    var cookie: HTTPCookie? {
        let props = Dictionary(uniqueKeysWithValues:
            dict.map { (HTTPCookiePropertyKey($0.key), $0.value as Any) })
        return HTTPCookie(properties: props)
    }

    init(_ cookie: HTTPCookie) {
        dict = (cookie.properties ?? [:])
            .compactMapValues { $0 as? String }
            .reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
    }
}

// MARK: - Errors

enum CXError: LocalizedError {
    case notLoggedIn
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "未登录学习通，请先扫码登录。"
        case .badResponse: return "服务器响应异常，请稍后重试。"
        }
    }
}
