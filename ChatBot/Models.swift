import Foundation

// MARK: - Provider

struct Provider: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var apiType: APIType
    var baseURL: String
    var models: [String]
    var iconName: String
    var colorHex: String
    var isBuiltin: Bool
    var customAPIKey: String

    enum APIType: String, Codable {
        case openAI, anthropic, gemini, openAICompatible
        case xiaomiMimo
    }

    init(id: String, name: String, apiType: APIType, baseURL: String,
         models: [String], iconName: String, colorHex: String,
         isBuiltin: Bool = false, customAPIKey: String = "") {
        self.id = id; self.name = name; self.apiType = apiType
        self.baseURL = baseURL; self.models = models
        self.iconName = iconName; self.colorHex = colorHex
        self.isBuiltin = isBuiltin; self.customAPIKey = customAPIKey
    }

    static let openAI = Provider(
        id: "openai", name: "OpenAI", apiType: .openAI,
        baseURL: "https://api.openai.com",
        models: ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"],
        iconName: "brain", colorHex: "10A37F", isBuiltin: true)
    static let anthropic = Provider(
        id: "anthropic", name: "Anthropic", apiType: .anthropic,
        baseURL: "https://api.anthropic.com",
        models: ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
        iconName: "sparkles", colorHex: "CC785C", isBuiltin: true)
    static let gemini = Provider(
        id: "gemini", name: "Gemini", apiType: .gemini,
        baseURL: "https://generativelanguage.googleapis.com",
        models: ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"],
        iconName: "star.circle", colorHex: "4285F4", isBuiltin: true)
    static let xiaomiMimo = Provider(
        id: "xiaomimimo", name: "小米 MiMo", apiType: .xiaomiMimo,
        baseURL: "https://token-plan-sgp.xiaomimimo.com/v1",
        // Token Plan OpenAI-compatible chat model.
        models: ["mimo-v2.5-pro"],
        iconName: "m.circle.fill", colorHex: "FF6900", isBuiltin: true)
    static let builtins: [Provider] = [.openAI, .anthropic, .gemini, .xiaomiMimo]
}

extension Provider {
    var defaultModel: String { models.first ?? "default" }
    var supportsBalanceCheck: Bool {
        !isBuiltin || apiType == .openAICompatible
    }
}

// MARK: - Usage & Pricing

struct UsageStats: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheHitTokens: Int = 0
    var cacheMissTokens: Int = 0
    var reasoningTokens: Int = 0
    var estimatedCostUSD: Double?

    var totalTokens: Int { inputTokens + outputTokens }
    var hasCache: Bool { cacheHitTokens > 0 }
    var hasReasoning: Bool { reasoningTokens > 0 }
}

struct ModelPricing {
    let inputPerM: Double    // cache miss
    let cachedPerM: Double   // cache hit
    let outputPerM: Double

    func cost(for usage: UsageStats) -> Double {
        let inputCost  = Double(usage.cacheMissTokens > 0 ? usage.cacheMissTokens : usage.inputTokens) / 1_000_000 * inputPerM
        let cachedCost = Double(usage.cacheHitTokens) / 1_000_000 * cachedPerM
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerM
        return inputCost + cachedCost + outputCost
    }
}

// USD per 1M tokens — updated April 2026
let knownPricing: [String: ModelPricing] = [
    // OpenAI
    "gpt-4o":               ModelPricing(inputPerM: 2.50,  cachedPerM: 1.25,  outputPerM: 10.00),
    "gpt-4o-mini":          ModelPricing(inputPerM: 0.15,  cachedPerM: 0.075, outputPerM: 0.60),
    "gpt-4-turbo":          ModelPricing(inputPerM: 10.00, cachedPerM: 5.00,  outputPerM: 30.00),
    "gpt-3.5-turbo":        ModelPricing(inputPerM: 0.50,  cachedPerM: 0.25,  outputPerM: 1.50),
    // Anthropic
    "claude-opus-4-7":               ModelPricing(inputPerM: 15.00, cachedPerM: 1.50,  outputPerM: 75.00),
    "claude-sonnet-4-6":             ModelPricing(inputPerM: 3.00,  cachedPerM: 0.30,  outputPerM: 15.00),
    "claude-haiku-4-5-20251001":     ModelPricing(inputPerM: 0.80,  cachedPerM: 0.08,  outputPerM: 4.00),
    // Gemini
    "gemini-2.0-flash":     ModelPricing(inputPerM: 0.10,  cachedPerM: 0.025, outputPerM: 0.40),
    "gemini-1.5-pro":       ModelPricing(inputPerM: 1.25,  cachedPerM: 0.313, outputPerM: 5.00),
    "gemini-1.5-flash":     ModelPricing(inputPerM: 0.075, cachedPerM: 0.019, outputPerM: 0.30),
    // DeepSeek
    "deepseek-chat":        ModelPricing(inputPerM: 0.27,  cachedPerM: 0.07,  outputPerM: 1.10),
    "deepseek-reasoner":    ModelPricing(inputPerM: 0.55,  cachedPerM: 0.14,  outputPerM: 2.19),
    "deepseek-v3":          ModelPricing(inputPerM: 0.27,  cachedPerM: 0.07,  outputPerM: 1.10),
    "deepseek-r1":          ModelPricing(inputPerM: 0.55,  cachedPerM: 0.14,  outputPerM: 2.19),
    // Xiaomi MiMo
    "mimo-v2-flash":        ModelPricing(inputPerM: 0.10,  cachedPerM: 0.05,  outputPerM: 0.30),
    "mimo-v2-pro":          ModelPricing(inputPerM: 0.50,  cachedPerM: 0.25,  outputPerM: 1.50),
]

// MARK: - Balance

struct ProviderBalance: Identifiable {
    let id = UUID()
    let currency: String
    let total: String
    let granted: String
    let toppedUp: String
}

enum APIReachabilityState: String {
    case reachable
    case authIssue
    case endpointIssue
    case networkIssue
}

struct APIReachabilityResult: Identifiable, Equatable {
    let id = UUID()
    var state: APIReachabilityState
    var statusCode: Int?
    var latencyMS: Int
    var message: String
    var checkedAt: Date = Date()

    var isReachable: Bool {
        state != .networkIssue
    }
}

// MARK: - Stream event

enum StreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    case usage(UsageStats)
}

// MARK: - Message

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    var role: MessageRole
    var content: String
    let timestamp: Date
    var reasoningContent: String?
    var usage: UsageStats?
    var schedulePayload: SchedulePayload?
    var chatListPayload: ChatListPayload?

    init(id: UUID = UUID(), role: MessageRole, content: String,
         timestamp: Date = Date(), reasoningContent: String? = nil, usage: UsageStats? = nil,
         schedulePayload: SchedulePayload? = nil, chatListPayload: ChatListPayload? = nil) {
        self.id = id; self.role = role; self.content = content
        self.timestamp = timestamp; self.reasoningContent = reasoningContent; self.usage = usage
        self.schedulePayload = schedulePayload
        self.chatListPayload = chatListPayload
    }
}

enum MessageRole: String, Codable { case user, assistant, system }

// MARK: - Chat Native UI Payloads

struct ChatListPayload: Codable, Equatable {
    var title: String
    var subtitle: String?
    var style: String
    var items: [ChatListItem]
}

struct ChatListItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var detail: String?
    var badge: String?
    var priority: String?
    var isDone: Bool?
}

// MARK: - Chat Skill

struct ChatSkill: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var description: String
    var instructions: String
    var scripts: [ChatSkillScript]
    var license: String?
    var compatibility: String?
    var allowedTools: String?
    var isEnabled: Bool

    init(id: UUID = UUID(),
         name: String,
         description: String,
         instructions: String,
         scripts: [ChatSkillScript] = [],
         license: String? = nil,
         compatibility: String? = nil,
         allowedTools: String? = nil,
         isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.scripts = scripts
        self.license = license
        self.compatibility = compatibility
        self.allowedTools = allowedTools
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, instructions, prompt, scripts, license, compatibility, allowedTools, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            ?? container.decodeIfPresent(String.self, forKey: .prompt)
            ?? ""
        scripts = try container.decodeIfPresent([ChatSkillScript].self, forKey: .scripts) ?? []
        license = try container.decodeIfPresent(String.self, forKey: .license)
        compatibility = try container.decodeIfPresent(String.self, forKey: .compatibility)
        allowedTools = try container.decodeIfPresent(String.self, forKey: .allowedTools)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(scripts, forKey: .scripts)
        try container.encodeIfPresent(license, forKey: .license)
        try container.encodeIfPresent(compatibility, forKey: .compatibility)
        try container.encodeIfPresent(allowedTools, forKey: .allowedTools)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

struct ChatSkillScript: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var relativePath: String
    var language: String
    var content: String

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

// MARK: - Quick Capture

struct QuickCaptureItem: Identifiable, Codable, Equatable {
    var id: UUID
    var sourceApp: String
    var capturedAt: Date
    var updatedAt: Date
    var text: String

    init(id: UUID = UUID(), sourceApp: String, capturedAt: Date = Date(), updatedAt: Date = Date(), text: String) {
        self.id = id
        self.sourceApp = sourceApp
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
        self.text = text
    }
}

struct CompanionClipboardOffer: Identifiable, Equatable {
    var id = UUID()
    var sourceApp: String
    var capturedAt: Date
    var text: String
}

enum ChatAgentMode: String, CaseIterable, Identifiable, Codable {
    case normal
    case multiAgent
    case subAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "普通"
        case .multiAgent: return "Multi"
        case .subAgent: return "Sub"
        }
    }

    var iconName: String {
        switch self {
        case .normal: return "bubble.left.and.bubble.right"
        case .multiAgent: return "person.3.fill"
        case .subAgent: return "arrow.triangle.branch"
        }
    }
}

struct ChatAgentVisualStep: Identifiable, Equatable {
    enum Status: String, Equatable {
        case waiting
        case running
        case done
        case failed
    }

    var id = UUID()
    var title: String
    var detail: String
    var status: Status
}

struct ChatAgentVisualization: Identifiable, Equatable {
    var id = UUID()
    var conversationID: UUID
    var mode: ChatAgentMode
    var title: String
    var steps: [ChatAgentVisualStep]
    var updatedAt = Date()
}

struct ChatToolConfirmation: Identifiable, Equatable {
    var id = UUID()
    var conversationID: UUID
    var title: String
    var detail: String
    var tools: [ChatToolConfirmationItem]
}

struct ChatToolConfirmationItem: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var title: String
    var detail: String
}

struct ContextWindowStats: Equatable {
    var estimatedTokens: Int
    var maxTokens: Int
    var summarizedMessageCount: Int

    var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return min(Double(estimatedTokens) / Double(maxTokens), 1)
    }
}

struct ShoppingListItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var quantity: String?
    var note: String?
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         quantity: String? = nil,
         note: String? = nil,
         isDone: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.quantity = quantity
        self.note = note
        self.isDone = isDone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

typealias ShoppingItem = ShoppingListItem

extension ShoppingListItem {
    var isCompleted: Bool {
        get { isDone }
        set {
            isDone = newValue
            updatedAt = Date()
        }
    }
}

// MARK: - Schedule Agent Payload

struct SchedulePayload: Codable, Equatable {
    var courses: [ScheduleCalendarEventItem] = []
    var chaoxingAssignments: [ScheduleChaoxingAssignmentItem] = []
    var chaoxingMessages: [ScheduleChaoxingMessageInsightItem] = []
    var reminders: [ScheduleReminderItem] = []
    var lists: [ScheduleReminderListItem] = []
    var calendars: [ScheduleCalendarItem] = []
    var events: [ScheduleCalendarEventItem] = []
    var actions: [ScheduleActionItem] = []

    var isEmpty: Bool {
        courses.isEmpty && chaoxingAssignments.isEmpty && chaoxingMessages.isEmpty && reminders.isEmpty && lists.isEmpty && calendars.isEmpty && events.isEmpty && actions.isEmpty
    }

    var containsOnlyCourses: Bool {
        !courses.isEmpty && chaoxingAssignments.isEmpty && chaoxingMessages.isEmpty && reminders.isEmpty && lists.isEmpty && calendars.isEmpty && events.isEmpty && actions.isEmpty
    }

    mutating func merge(_ other: SchedulePayload) {
        courses.append(contentsOf: other.courses)
        chaoxingAssignments.append(contentsOf: other.chaoxingAssignments)
        chaoxingMessages.append(contentsOf: other.chaoxingMessages)
        reminders.append(contentsOf: other.reminders.filter { !$0.isCompleted })
        lists.append(contentsOf: other.lists)
        calendars.append(contentsOf: other.calendars)
        events.append(contentsOf: other.events)
        actions.append(contentsOf: other.actions)
    }

    enum CodingKeys: String, CodingKey {
        case courses, chaoxingAssignments, chaoxingMessages, reminders, lists, calendars, events, actions
    }

    init(courses: [ScheduleCalendarEventItem] = [],
         chaoxingAssignments: [ScheduleChaoxingAssignmentItem] = [],
         chaoxingMessages: [ScheduleChaoxingMessageInsightItem] = [],
         reminders: [ScheduleReminderItem] = [],
         lists: [ScheduleReminderListItem] = [],
         calendars: [ScheduleCalendarItem] = [],
         events: [ScheduleCalendarEventItem] = [],
         actions: [ScheduleActionItem] = []) {
        self.courses = courses
        self.chaoxingAssignments = chaoxingAssignments
        self.chaoxingMessages = chaoxingMessages
        self.reminders = reminders
        self.lists = lists
        self.calendars = calendars
        self.events = events
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courses = try container.decodeIfPresent([ScheduleCalendarEventItem].self, forKey: .courses) ?? []
        chaoxingAssignments = try container.decodeIfPresent([ScheduleChaoxingAssignmentItem].self, forKey: .chaoxingAssignments) ?? []
        chaoxingMessages = try container.decodeIfPresent([ScheduleChaoxingMessageInsightItem].self, forKey: .chaoxingMessages) ?? []
        reminders = try container.decodeIfPresent([ScheduleReminderItem].self, forKey: .reminders) ?? []
        lists = try container.decodeIfPresent([ScheduleReminderListItem].self, forKey: .lists) ?? []
        calendars = try container.decodeIfPresent([ScheduleCalendarItem].self, forKey: .calendars) ?? []
        events = try container.decodeIfPresent([ScheduleCalendarEventItem].self, forKey: .events) ?? []
        actions = try container.decodeIfPresent([ScheduleActionItem].self, forKey: .actions) ?? []
    }
}

struct ScheduleReminderItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var listName: String
    var dueDate: Date?
    var notes: String?
    var isCompleted: Bool
}

struct ScheduleReminderListItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
}

struct ScheduleCalendarItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
}

struct ScheduleCalendarEventItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var calendarName: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?
    var isAllDay: Bool
}

struct ScheduleChaoxingAssignmentItem: Identifiable, Codable, Equatable {
    var id: String
    var originalID: String
    var courseID: String
    var courseName: String
    var title: String
    var dueDate: Date
    var status: String
    var type: String
    var remainingTime: String
}

struct ScheduleChaoxingMessageInsightItem: Identifiable, Codable, Equatable {
    var id: String
    var sourceMessageID: String
    var conversationID: String
    var conversationName: String
    var senderID: String
    /// Human-readable display name from fromUser.nickname. Nil for system/unknown senders.
    var senderName: String?
    var title: String
    var summary: String
    var reason: String
    var actionHint: String?
    var importance: String
    var sentAt: Date
    var extractedAt: Date
    var sourceTextPreview: String
}

struct ScheduleActionItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: String
    var title: String
    var detail: String
    var reminderID: String? = nil
    var calendarEventID: String? = nil
}

struct SchedulePendingConfirmation: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var confirmTitle: String
    var isDestructive: Bool
    var payload: SchedulePayload?
}

struct ScheduleSidebarSnapshot: Equatable {
    var courses: [ScheduleCalendarEventItem] = []
    var chaoxingAssignments: [ScheduleChaoxingAssignmentItem] = []
    var chaoxingMessageInsights: [ScheduleChaoxingMessageInsightItem] = []
    var events: [ScheduleCalendarEventItem] = []
    var weekEvents: [ScheduleCalendarEventItem] = []
    var reminders: [ScheduleReminderItem] = []
}

struct TodayAttentionItem: Identifiable, Codable, Equatable {
    var id: String
    var kind: String
    var title: String
    var detail: String
    var date: Date?
    var score: Double
    /// primary = now/today, upcoming = next ~48h, background = farther context
    var horizon: String
}

struct TodayWidgetSummarySource: Codable, Equatable {
    var attentionItems: [TodayAttentionItem]
    var todayAssignments: [ScheduleChaoxingAssignmentItem]
    var importantReminders: [ScheduleReminderItem]
    var importantEvents: [ScheduleCalendarEventItem]
    var todayDueReminders: [ScheduleReminderItem]
    var todayEvents: [ScheduleCalendarEventItem]
    var todayCourses: [ScheduleCalendarEventItem]
    var allAssignments: [ScheduleChaoxingAssignmentItem]
    var allActiveReminders: [ScheduleReminderItem]
    var allUpcomingEvents: [ScheduleCalendarEventItem]
    var allUpcomingCourses: [ScheduleCalendarEventItem]
    var memoryHighlights: [ScheduleChaoxingMessageInsightItem]
    var courseWarnings: [ScheduleChaoxingMessageInsightItem]
    var quickCaptures: [QuickCaptureItem]
    var recentConversationMessages: [Message]
    var recentScheduleMessages: [Message]
}

struct TodayWidgetSnapshot: Codable, Equatable {
    var summary: String = "未生成"
    var sourceHash: String = ""
    var generatedAt: Date?
    var attentionItems: [TodayAttentionItem] = []
    var assignments: [ScheduleChaoxingAssignmentItem] = []
    var importantReminders: [ScheduleReminderItem] = []
    var importantEvents: [ScheduleCalendarEventItem] = []
    var memoryHighlights: [ScheduleChaoxingMessageInsightItem] = []
    /// Upcoming events/reminders within the next 7 days (not just today)
    var upcomingEvents: [ScheduleCalendarEventItem] = []
    var upcomingReminders: [ScheduleReminderItem] = []

    var hasVisibleItems: Bool {
        !attentionItems.isEmpty || !assignments.isEmpty || !importantReminders.isEmpty || !importantEvents.isEmpty || !memoryHighlights.isEmpty
    }

    init(summary: String = "未生成",
         sourceHash: String = "",
         generatedAt: Date? = nil,
         attentionItems: [TodayAttentionItem] = [],
         assignments: [ScheduleChaoxingAssignmentItem] = [],
         importantReminders: [ScheduleReminderItem] = [],
         importantEvents: [ScheduleCalendarEventItem] = [],
         memoryHighlights: [ScheduleChaoxingMessageInsightItem] = [],
         upcomingEvents: [ScheduleCalendarEventItem] = [],
         upcomingReminders: [ScheduleReminderItem] = []) {
        self.summary = summary
        self.sourceHash = sourceHash
        self.generatedAt = generatedAt
        self.attentionItems = attentionItems
        self.assignments = assignments
        self.importantReminders = importantReminders
        self.importantEvents = importantEvents
        self.memoryHighlights = memoryHighlights
        self.upcomingEvents = upcomingEvents
        self.upcomingReminders = upcomingReminders
    }

    enum CodingKeys: String, CodingKey {
        case summary, sourceHash, generatedAt, attentionItems, assignments, importantReminders, importantEvents, memoryHighlights, upcomingEvents, upcomingReminders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? "未生成"
        sourceHash = try container.decodeIfPresent(String.self, forKey: .sourceHash) ?? ""
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        attentionItems = try container.decodeIfPresent([TodayAttentionItem].self, forKey: .attentionItems) ?? []
        assignments = try container.decodeIfPresent([ScheduleChaoxingAssignmentItem].self, forKey: .assignments) ?? []
        importantReminders = try container.decodeIfPresent([ScheduleReminderItem].self, forKey: .importantReminders) ?? []
        importantEvents = try container.decodeIfPresent([ScheduleCalendarEventItem].self, forKey: .importantEvents) ?? []
        memoryHighlights = try container.decodeIfPresent([ScheduleChaoxingMessageInsightItem].self, forKey: .memoryHighlights) ?? []
        upcomingEvents = try container.decodeIfPresent([ScheduleCalendarEventItem].self, forKey: .upcomingEvents) ?? []
        upcomingReminders = try container.decodeIfPresent([ScheduleReminderItem].self, forKey: .upcomingReminders) ?? []
    }
}

struct CourseMemoryAnnotation: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var detail: String
    var actionHint: String?
    var importance: String
}

struct ChaoxingRuntimeSyncStatus: Codable, Equatable {
    var isRunning: Bool = false
    var isRefreshing: Bool = false
    var lastProbeAt: Date?
    var lastFullFetchAt: Date?
    var lastSuccessfulFetchAt: Date?
    var nextRefreshAt: Date?
    var lastError: String?
    var consecutiveNoChangeCount: Int = 0
    var activeImportanceWindowUntil: Date?
}

struct CompanionState: Codable, Equatable {
    var mood: String = "idle"
    var pose: String = "idle"
    var bubble: String = "今天我会安静盯着日程。"
    var urgency: String = "none"
    var suggestedAction: String = "open_today"
    var suggestions: [String] = []
    var sourceHash: String = ""
    var generatedAt: Date?
    var llmBacked: Bool = false
}

struct CompanionPreferences: Codable, Equatable {
    var isEnabled: Bool = true
    var useLLMFeedback: Bool = true
    var quietUntil: Date?
}

enum CompanionHiddenEdge: String {
    case left
    case right
}

struct CoursePeriod: Identifiable, Equatable {
    let id: Int
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int

    var label: String { "\(id)" }
}

let defaultCoursePeriods: [CoursePeriod] = [
    CoursePeriod(id: 1, startHour: 8, startMinute: 0, endHour: 8, endMinute: 45),
    CoursePeriod(id: 2, startHour: 8, startMinute: 50, endHour: 9, endMinute: 35),
    CoursePeriod(id: 3, startHour: 9, startMinute: 50, endHour: 10, endMinute: 35),
    CoursePeriod(id: 4, startHour: 10, startMinute: 40, endHour: 11, endMinute: 25),
    CoursePeriod(id: 5, startHour: 11, startMinute: 30, endHour: 12, endMinute: 15),
    CoursePeriod(id: 6, startHour: 13, startMinute: 30, endHour: 14, endMinute: 15),
    CoursePeriod(id: 7, startHour: 14, startMinute: 20, endHour: 15, endMinute: 5),
    CoursePeriod(id: 8, startHour: 15, startMinute: 20, endHour: 16, endMinute: 5),
    CoursePeriod(id: 9, startHour: 16, startMinute: 10, endHour: 16, endMinute: 55),
    CoursePeriod(id: 10, startHour: 18, startMinute: 30, endHour: 19, endMinute: 15),
    CoursePeriod(id: 11, startHour: 19, startMinute: 20, endHour: 20, endMinute: 5),
    CoursePeriod(id: 12, startHour: 20, startMinute: 10, endHour: 20, endMinute: 55)
]

// MARK: - Conversation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]
    var providerID: String
    var model: String
    var agentMode: ChatAgentMode
    var systemPrompt: String
    var contextSummary: String?
    var contextSummaryMessageCount: Int?
    var contextSummaryUpdatedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    var totalUsage: UsageStats {
        messages.filter { $0.role == .assistant }.compactMap(\.usage).reduce(into: UsageStats()) { acc, u in
            acc.inputTokens    += u.inputTokens
            acc.outputTokens   += u.outputTokens
            acc.cacheHitTokens += u.cacheHitTokens
            acc.cacheMissTokens += u.cacheMissTokens
            acc.reasoningTokens += u.reasoningTokens
            if let c1 = acc.estimatedCostUSD, let c2 = u.estimatedCostUSD {
                acc.estimatedCostUSD = c1 + c2
            } else if let c2 = u.estimatedCostUSD {
                acc.estimatedCostUSD = c2
            }
        }
    }

    init(id: UUID = UUID(), title: String = "New Chat", messages: [Message] = [],
        providerID: String = "openai", model: String = "gpt-4o",
         agentMode: ChatAgentMode = .normal,
         systemPrompt: String = "", createdAt: Date = Date()) {
        self.id = id; self.title = title; self.messages = messages
        self.providerID = providerID; self.model = model; self.agentMode = agentMode
        self.systemPrompt = systemPrompt
        self.contextSummary = nil
        self.contextSummaryMessageCount = nil
        self.contextSummaryUpdatedAt = nil
        self.createdAt = createdAt; self.updatedAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, providerID, model, agentMode, systemPrompt
        case contextSummary, contextSummaryMessageCount, contextSummaryUpdatedAt
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        providerID = try container.decode(String.self, forKey: .providerID)
        model = try container.decode(String.self, forKey: .model)
        agentMode = try container.decodeIfPresent(ChatAgentMode.self, forKey: .agentMode) ?? .normal
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        contextSummaryMessageCount = try container.decodeIfPresent(Int.self, forKey: .contextSummaryMessageCount)
        contextSummaryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .contextSummaryUpdatedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
