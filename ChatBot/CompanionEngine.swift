import CryptoKit
import Foundation

enum CompanionEngine {
    private struct CompanionBrief {
        var bubble: String
        var suggestions: [String]
        var urgency: String
        var source: String
    }

    static func makeState(today: TodayWidgetSnapshot,
                          memory: [ScheduleChaoxingMessageInsightItem],
                          syncStatus: ChaoxingRuntimeSyncStatus,
                          now: Date = Date()) -> CompanionState {
        let brief = companionBrief(today: today, memory: memory, syncStatus: syncStatus, now: now)

        let topAttention = today.attentionItems.first
        let highMemory = memory.first { $0.importance == "high" }
        let urgentEvent = today.importantEvents.first {
            $0.startDate.timeIntervalSince(now) >= 0 && $0.startDate.timeIntervalSince(now) <= 3 * 60 * 60
        }
        let urgentReminder = today.importantReminders.first {
            if let d = $0.dueDate { return d.timeIntervalSince(now) >= -3600 && d.timeIntervalSince(now) <= 3 * 60 * 60 }
            return false
        }
        let urgentAssignment = today.assignments.first {
            $0.dueDate.timeIntervalSince(now) >= -3600 && $0.dueDate.timeIntervalSince(now) <= 3 * 60 * 60
        }

        let mood: String
        let pose: String
        let urgency: String
        let bubble: String
        let action: String

        if let topAttention, topAttention.score >= 110 {
            mood = "concerned"
            pose = "alert"
            urgency = brief.urgency
            bubble = brief.bubble
            action = "open_today"
        } else if let topAttention, topAttention.horizon == "primary" {
            mood = "focused"
            pose = "pointing"
            urgency = brief.urgency
            bubble = brief.bubble
            action = "open_today"
        } else if highMemory != nil {
            mood = "concerned"
            pose = "alert"
            urgency = brief.urgency
            bubble = brief.bubble
            action = "open_today"
        } else if let urgentEvent {
            mood = "focused"
            pose = "alert"
            urgency = "high"
            bubble = "稍后有日程：\(urgentEvent.title)"
            action = "open_today"
        } else if let urgentReminder {
            mood = "focused"
            pose = "pointing"
            urgency = "medium"
            bubble = "\(urgentReminder.title) 马上到期了。"
            action = "open_today"
        } else if let urgentAssignment {
            mood = "focused"
            pose = "pointing"
            urgency = "medium"
            bubble = "\(urgentAssignment.title) 快到截止时间了。"
            action = "open_today"
        } else if let topAttention, topAttention.horizon == "upcoming" {
            mood = "focused"
            pose = "thinking"
            urgency = brief.urgency
            bubble = brief.bubble
            action = "open_today"
        } else if !today.assignments.isEmpty || !today.importantReminders.isEmpty || !today.importantEvents.isEmpty {
            mood = "focused"
            pose = "thinking"
            urgency = "low"
            bubble = "今天有几件事，慢慢来。"
            action = "open_today"
        } else if syncStatus.isRefreshing {
            mood = "curious"
            pose = "thinking"
            urgency = "none"
            bubble = "我在轻轻检查学习通。"
            action = "none"
        } else {
            mood = "calm"
            pose = "idle"
            urgency = "none"
            bubble = brief.bubble
            action = "open_today"
        }

        let source = [
            mood,
            pose,
            urgency,
            bubble,
            brief.source,
            syncStatus.lastSuccessfulFetchAt.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? ""
        ].joined(separator: "::")

        return CompanionState(
            mood: mood,
            pose: pose,
            bubble: ChaoxingTextNormalizer.preview(bubble, limit: 34),
            urgency: urgency,
            suggestedAction: action,
            suggestions: brief.suggestions,
            sourceHash: stableHash(source),
            generatedAt: now,
            llmBacked: false
        )
    }

    private static func companionBrief(today: TodayWidgetSnapshot,
                                       memory: [ScheduleChaoxingMessageInsightItem],
                                       syncStatus: ChaoxingRuntimeSyncStatus,
                                       now: Date) -> CompanionBrief {
        let top = today.attentionItems.first
        let primary = today.attentionItems.filter { $0.horizon == "primary" }
        let upcoming = today.attentionItems.filter { $0.horizon == "upcoming" }

        var bubble: String
        var urgency = "none"
        if let top {
            let when = top.date.map { compactRelativeTime($0, now: now) }
            switch top.horizon {
            case "primary":
                urgency = top.score >= 95 ? "high" : "medium"
                bubble = when.map { "\($0)：\(top.title)" } ?? top.title
            case "upcoming":
                urgency = top.score >= 80 ? "medium" : "low"
                bubble = when.map { "\($0)留意 \(top.title)" } ?? "两天内留意 \(top.title)"
            default:
                urgency = "low"
                bubble = top.title
            }
        } else if let highMemory = memory.first(where: { $0.importance == "high" }) {
            urgency = "high"
            bubble = highMemory.actionHint ?? highMemory.title
        } else if syncStatus.isRefreshing {
            bubble = "我在检查学习通。"
        } else {
            bubble = "目前看起来还挺清爽。"
        }

        var suggestions = (primary + upcoming)
            .prefix(2)
            .map { item in item.date.map { "\(compactRelativeTime($0, now: now)) \(item.title)" } ?? item.title }

        if suggestions.isEmpty {
            suggestions = today.memoryHighlights.prefix(2).map { $0.actionHint ?? $0.summary }
        }

        suggestions = suggestions
            .map { ChaoxingTextNormalizer.preview($0, limit: 22) }
            .filter { !$0.isEmpty }

        bubble = ChaoxingTextNormalizer.preview(bubble, limit: 24)
        let source = [
            bubble,
            urgency,
            suggestions.joined(separator: "|"),
            top.map { "\($0.id):\(Int($0.score))" } ?? ""
        ].joined(separator: "::")

        return CompanionBrief(
            bubble: bubble,
            suggestions: Array(suggestions.prefix(2)),
            urgency: urgency,
            source: source
        )
    }

    private static func compactRelativeTime(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = shortTime(date)
        if calendar.isDateInToday(date) { return "今天\(time)" }
        if calendar.isDateInTomorrow(date) { return "明天\(time)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    static func llmPrompt(for state: CompanionState, today: TodayWidgetSnapshot) -> String {
        """
        You are a tiny desktop companion for a Chinese schedule app.
        Rewrite the bubble in cute, calm Chinese. Keep it useful, not childish.
        Constraints:
        - 10 to 28 Chinese characters.
        - No markdown.
        - Do not mention you are an AI.
        - Do not invent tasks.

        Mood: \(state.mood)
        Urgency: \(state.urgency)
        Current bubble: \(state.bubble)
        Suggestions: \(state.suggestions.joined(separator: " / "))
        Today summary: \(today.summary)
        """
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
import SwiftUI
import AppKit

// MARK: - Window Manager

final class CompanionPetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompanionPetWindowManager {
    static let shared = CompanionPetWindowManager()

    private var panel: CompanionPetPanel?
    private weak var viewModel: ChatViewModel?
    private var hiddenEdge: CompanionHiddenEdge?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private init() {}

    private let panelSize = NSSize(width: 208, height: 88)
    private let hiddenStrip: CGFloat = 18
    private let frameDefaultsKey = "companion_pet_window_frame"

    func configure(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        if viewModel.companionPreferences.isEnabled { show() }
    }

    func show() {
        guard let viewModel else { return }
        if panel == nil {
            let newPanel = CompanionPetPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .floating
            newPanel.isMovableByWindowBackground = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let host = NSHostingView(rootView: CompanionPetView().environmentObject(viewModel))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: panelSize)
            newPanel.contentView?.addSubview(host)
            self.panel = newPanel
            installMouseMonitors()
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        hiddenEdge = nil
    }

    private func positionPanel() {
        guard let panel else { return }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = restoredFrame(in: visible)?.origin
            ?? NSPoint(x: visible.maxX - panelSize.width - 16, y: visible.minY + 64)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.contentView?.subviews.first?.frame = NSRect(origin: .zero, size: panelSize)
    }

    private func restoredFrame(in visible: NSRect) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: frameDefaultsKey) else { return nil }
        var frame = NSRectFromString(raw)
        guard frame.width > 40, frame.height > 40 else { return nil }
        frame.size = panelSize
        let paddedVisible = visible.insetBy(dx: -panelSize.width + hiddenStrip, dy: -8)
        guard paddedVisible.intersects(frame) else { return nil }
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        return frame
    }

    private func savePanelFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameDefaultsKey)
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        switch event.type {
        case .leftMouseUp:
            snapToEdgeIfNeeded()
            savePanelFrame()
        case .mouseMoved:
            if hiddenEdge != nil {
                revealIfPointerTouchesEdge()
            } else if panel.frame.contains(NSEvent.mouseLocation) {
                revealFromEdge()
            }
        default:
            break
        }
    }

    private func snapToEdgeIfNeeded() {
        guard let panel else { return }
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = panel.frame
        let threshold: CGFloat = 16
        if frame.minX <= visible.minX + threshold {
            hideToEdge(.left, visible: visible)
        } else if frame.maxX >= visible.maxX - threshold {
            hideToEdge(.right, visible: visible)
        }
    }

    private func hideToEdge(_ edge: CompanionHiddenEdge, visible: NSRect) {
        guard let panel else { return }
        hiddenEdge = edge
        var frame = panel.frame
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        switch edge {
        case .left:
            frame.origin.x = visible.minX - frame.width + hiddenStrip
        case .right:
            frame.origin.x = visible.maxX - hiddenStrip
        }
        panel.setFrame(frame, display: true, animate: true)
        savePanelFrame()
    }

    private func revealIfPointerTouchesEdge() {
        guard let panel, let hiddenEdge else { return }
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let pointer = NSEvent.mouseLocation
        let verticalBand = panel.frame.insetBy(dx: -4, dy: -12)
        guard pointer.y >= verticalBand.minY, pointer.y <= verticalBand.maxY else { return }
        switch hiddenEdge {
        case .left where pointer.x <= visible.minX + hiddenStrip + 6:
            revealFromEdge()
        case .right where pointer.x >= visible.maxX - hiddenStrip - 6:
            revealFromEdge()
        default:
            break
        }
    }

    private func revealFromEdge() {
        guard let panel, let hiddenEdge else { return }
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var frame = panel.frame
        switch hiddenEdge {
        case .left:
            frame.origin.x = visible.minX + 10
        case .right:
            frame.origin.x = visible.maxX - frame.width - 10
        }
        self.hiddenEdge = nil
        panel.setFrame(frame, display: true, animate: true)
        savePanelFrame()
    }
}

// MARK: - Companion Pet View

struct CompanionPetView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    // ── Animation ────────────────────────────────────────────
    @State private var breathLift: CGFloat = 0
    @State private var isRewriting = false
    @State private var isEating    = false
    @State private var bubbleScale: CGFloat = 1

    // Panel: compact enough to live at the screen edge.
    private let W: CGFloat = 208
    private let H: CGFloat = 88

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            HStack(alignment: .center, spacing: 0) {
                speechBubble
                    .scaleEffect(bubbleScale, anchor: .trailing)
                    .animation(.spring(response: 0.32, dampingFraction: 0.72), value: bubbleScale)
                catColumn
            }
            .padding(.bottom, 8)
            .padding(.trailing, 6)
        }
        .frame(width: W, height: H)
        .contentShape(Rectangle())
        .onTapGesture { if viewModel.companionClipboardOffer == nil { rewriteSign() } }
        .onAppear { startAnimations() }
        .contextMenu {
            Button("重写建议") { rewriteSign() }
            Divider()
            if viewModel.companionClipboardOffer != nil {
                Button("发给聊天分析")          { analyzeClipboard() }
                Button("发给日程 Agent")       { eatClipboard(sendToAgent: true)  }
                Divider()
            }
            if !viewModel.quickCaptures.isEmpty {
                Button("中转站发给日程 Agent")  { viewModel.sendQuickCapturesToScheduleAgent() }
                Divider()
            }
            Button("安静 1 小时") { viewModel.snoozeCompanion(minutes: 60) }
            Button("隐藏桌宠")    { CompanionPetWindowManager.shared.hide() }
        }
        .help("右键更多选项")
    }

    // MARK: Speech Bubble (replaces the old glass card)

    @ViewBuilder
    private var speechBubble: some View {
        if let offer = viewModel.companionClipboardOffer {
            clipboardBubble(offer)
        } else {
            scheduleBubble
        }
    }

    /// Normal schedule/status bubble
    private var scheduleBubble: some View {
        ZStack(alignment: .leading) {
            // Glass fill + border via BubbleShape (tail on right)
            BubbleShape()
                .fill(.ultraThinMaterial)
            BubbleShape()
                .stroke(.white.opacity(0.22), lineWidth: 0.5)

            VStack(alignment: .leading, spacing: 5) {
                // ── Top row: urgency dot + label + spinner ──
                HStack(spacing: 5) {
                    Circle()
                        .fill(urgencyDot)
                        .frame(width: 5, height: 5)
                        .shadow(color: urgencyDot.opacity(0.7), radius: 2)
                    Text(urgencyLabel)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if viewModel.isChaoxingMessageExtractionRunning {
                        ProgressView().scaleEffect(0.42).frame(width: 9, height: 9)
                    }
                    if !viewModel.quickCaptures.isEmpty {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.orange)
                        Text("\(viewModel.quickCaptures.count)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }

                // ── Main text (most important item) ──
                Text(isRewriting ? "思考中…" : mainBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.quickSpring, value: mainBubbleText)

                // ── Secondary line ──
                if !secondaryText.isEmpty && !isRewriting {
                    Text(secondaryText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .animation(.quickSpring, value: secondaryText)
                }
            }
            // leave 14 pt on the right for the bubble tail
            .padding(.leading, 11).padding(.trailing, 22)
            .padding(.vertical, 10)
        }
        .frame(width: 138, height: 72)
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
    }

    /// Clipboard-offer bubble
    private func clipboardBubble(_ offer: CompanionClipboardOffer) -> some View {
        ZStack(alignment: .leading) {
            BubbleShape().fill(.ultraThinMaterial)
            BubbleShape().stroke(.white.opacity(0.22), lineWidth: 0.5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text("分析这个链接？")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { viewModel.dismissCompanionClipboardOffer() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Text(ChaoxingTextNormalizer.preview(offer.text, limit: 42))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Button { analyzeClipboard() } label: {
                        Text("分析").font(.system(size: 9, weight: .semibold))
                    }.buttonStyle(.borderedProminent).controlSize(.mini).tint(.blue)
                    Button { eatClipboard(sendToAgent: true) } label: {
                        Text("发日程").font(.system(size: 9, weight: .semibold))
                    }.buttonStyle(.bordered).controlSize(.mini)
                }
            }
            .padding(.leading, 11).padding(.trailing, 22).padding(.vertical, 9)
        }
        .frame(width: 138, height: 72)
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
    }

    // MARK: Cat Column

    private var catColumn: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(0.09))
                .frame(width: 38, height: 6)
                .blur(radius: 3)
                .offset(y: 1)
            catSprite
                .offset(y: breathLift)
        }
        .frame(width: 58, height: 72)
    }

    // MARK: Cat Sprite

    private var animationFrames: [String] {
        if isRewriting || isEating { return (0..<6).map { "cat_run_\($0)" } }
        switch viewModel.companionState.pose {
        case "alert", "pointing": return ["cat_sit_0"]
        case "thinking":          return (0..<6).map { "cat_walk_\($0)" }
        default:                  return ["cat_idle_0","cat_idle_0","cat_idle_0","cat_idle_1",
                                          "cat_idle_0","cat_idle_0","cat_idle_0","cat_idle_1"]
        }
    }

    private var frameDuration: Double {
        if isRewriting || isEating { return 0.09 }
        return viewModel.companionState.pose == "thinking" ? 0.13 : 0.50
    }

    private var catSprite: some View {
        TimelineView(.periodic(from: .now, by: frameDuration)) { tl in
            let frames = animationFrames
            let dur = frameDuration
            let idx = Int(tl.date.timeIntervalSinceReferenceDate / dur) % max(1, frames.count)
            Image(frames[idx])
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 58)
        }
    }

    // MARK: Computed text

    /// Primary bubble line — the cat's "speech"
    private var mainBubbleText: String {
        let raw: String
        // If companion has a meaningful bubble from the state engine, use it
        let stateBubble = viewModel.companionState.bubble
        if !stateBubble.isEmpty && stateBubble != "目前看起来还挺清爽。" {
            raw = stateBubble
        } else {
            // Fall back to soonest upcoming item
            raw = soonestItemText ?? viewModel.companionState.bubble
        }
        return ChaoxingTextNormalizer.preview(raw, limit: 32)
    }

    /// Secondary line — next time-bound item if main wasn't already that
    private var secondaryText: String {
        guard let text = soonestItemText else { return "" }
        // don't duplicate if already shown in main
        let main = mainBubbleText
        if main.contains(text.prefix(6)) { return "" }
        return ChaoxingTextNormalizer.preview(text, limit: 28)
    }

    private var soonestItemText: String? {
        let now = Date()
        var items: [(Date, String)] = []
        items += viewModel.todayWidget.assignments.map {
            ($0.dueDate, "\($0.title) 截止 \(shortTime($0.dueDate))")
        }
        items += viewModel.todayWidget.importantReminders.compactMap { r in
            r.dueDate.map { ($0, "\(r.title) 截止 \(shortTime($0))") }
        }
        items += viewModel.todayWidget.importantEvents.map {
            ($0.startDate, "\($0.title) \(shortTime($0.startDate))")
        }
        items += viewModel.todayWidget.upcomingEvents.map {
            ($0.startDate, "\($0.title) \(shortDate($0.startDate))")
        }
        return items
            .filter { $0.0 >= now.addingTimeInterval(-120) }
            .sorted { $0.0 < $1.0 }
            .first?.1
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }
    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: date)
    }

    // MARK: Colors

    private var urgencyDot: Color {
        switch viewModel.companionState.urgency {
        case "high":   return .orange
        case "medium": return .purple
        case "low":    return .blue
        default:       return Color(red: 0.36, green: 0.78, blue: 0.52)
        }
    }
    private var urgencyLabel: String {
        switch viewModel.companionState.urgency {
        case "high":   return "需要关注"
        case "medium": return "有待处理"
        case "low":    return "轻松模式"
        default:       return "一切正常"
        }
    }

    // MARK: Animations

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathLift = -2
        }
    }

    // MARK: Actions

    private func rewriteSign() {
        guard !isRewriting else { return }
        isRewriting = true
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { bubbleScale = 0.94 }
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { bubbleScale = 1.0 }
            viewModel.refreshCompanionState(reason: "sign")
            try? await Task.sleep(nanoseconds: 700_000_000)
            isRewriting = false
        }
    }

    private func eatClipboard(sendToAgent: Bool) {
        guard !isEating else { return }
        isEating = true
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            viewModel.acceptCompanionClipboardOffer(sendToAgent: sendToAgent)
            try? await Task.sleep(nanoseconds: 340_000_000)
            isEating = false
        }
    }

    private func analyzeClipboard() {
        guard !isEating else { return }
        isEating = true
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            viewModel.analyzeCompanionClipboardOffer()
            try? await Task.sleep(nanoseconds: 340_000_000)
            isEating = false
        }
    }
}

// MARK: - Speech Bubble Shape (tail on right, pointing toward the cat)

struct BubbleShape: Shape {
    var cornerRadius: CGFloat = 13
    var tailW: CGFloat = 12    // horizontal extent of tail
    var tailH: CGFloat = 14    // vertical span of tail base
    var tailMidY: CGFloat = 0.55  // 0…1 from top where tail center sits

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width - tailW, height: rect.height)
        let r = min(cornerRadius, body.height / 2, body.width / 2)
        let midY = rect.minY + rect.height * tailMidY
        let halfTail = tailH / 2

        var p = Path()
        // top-left corner
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r),
                 radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        // right side — split by tail
        p.addLine(to: CGPoint(x: body.maxX, y: midY - halfTail))
        // tail tip
        p.addLine(to: CGPoint(x: rect.maxX, y: midY))
        p.addLine(to: CGPoint(x: body.maxX, y: midY + halfTail))
        // continue right side down
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r),
                 radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // bottom
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r),
                 radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        // left side
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
