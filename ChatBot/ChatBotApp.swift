import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI
import Vision

@main
struct ChatBotApp: App {
    @StateObject private var viewModel = ChatViewModel()
    private let quickCapture = QuickCaptureManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    quickCapture.configure(viewModel: viewModel)
                    CompanionPetWindowManager.shared.configure(viewModel: viewModel)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Conversation") {
                    viewModel.createConversation()
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Clear Messages") {
                    viewModel.clearMessages()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}

// MARK: - Quick Capture

enum QuickCaptureMode: String, CaseIterable, Identifiable {
    case chat
    case schedule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .schedule: return "日程"
        }
    }

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .schedule: return "calendar.badge.clock"
        }
    }
}

final class QuickCaptureState: ObservableObject {
    @Published var mode: QuickCaptureMode = .schedule
    @Published var text = ""
    @Published var sourceApp = ""
    @Published var capturedAt = Date()
    @Published var status = ""
}

final class QuickCapturePanel: NSPanel {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class QuickCaptureManager {
    static let shared = QuickCaptureManager()

    private static let hotKeySignature = OSType("CBQC".fourCharCodeValue)
    private static let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)

    private weak var viewModel: ChatViewModel?
    private let state = QuickCaptureState()
    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var didConfigure = false
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastOfferedClipboardText = ""

    private init() {}

    func configure(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        guard !didConfigure else { return }
        didConfigure = true
        registerHotKey()
        startClipboardMonitor()
    }

    func showFromClipboard() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知 App"
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        state.sourceApp = frontmostApp == "ChatBot" ? "剪贴板" : frontmostApp
        state.capturedAt = Date()
        state.text = clipboard
        if clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.status = NSImage(pasteboard: .general) == nil ? "剪贴板里没有文本，可以手动粘贴。" : "正在识别剪贴板截图..."
        } else {
            state.status = ""
        }
        showPanel()

        if clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recognizeClipboardImage()
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func submitQuickAction() {
        switch state.mode {
        case .chat:
            sendQuickChat()
        case .schedule:
            saveCapture()
        }
    }

    private func sendQuickChat() {
        guard let viewModel else { return }
        let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.status = "先输入一条消息。"
            return
        }
        guard !viewModel.isStreaming else {
            state.status = "当前对话正在回复。"
            return
        }

        if viewModel.selectedConversation == nil {
            viewModel.createConversation()
        }
        NotificationCenter.default.post(name: .openChat, object: nil)
        viewModel.startSendingMessage(trimmed)
        closePanel()
    }

    private func saveCapture() {
        guard let viewModel else { return }
        let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.status = "先粘贴一段聊天通知。"
            return
        }

        _ = viewModel.addQuickCapture(text: trimmed, sourceApp: state.sourceApp, capturedAt: state.capturedAt)
        if viewModel.quickCaptureOpenScheduleAfterSave {
            NotificationCenter.default.post(name: .openScheduleAgent, object: nil)
        }
        closePanel()
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 86
            )
            panel.setFrameOrigin(origin)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func recognizeClipboardImage() {
        guard let image = NSImage(pasteboard: .general) else {
            state.status = "剪贴板里没有截图。"
            return
        }

        state.status = "正在识别剪贴板截图..."
        Task {
            let recognized = await Self.recognizeText(in: image)
            let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state.status = "没有识别到文字，可以手动粘贴。"
            } else {
                state.text = trimmed
                state.status = "已从截图识别文字。"
            }
        }
    }

    private func startClipboardMonitor() {
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboardForCompanion()
            }
        }
    }

    private func checkClipboardForCompanion() {
        guard let viewModel else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        let text = pasteboard.string(forType: .string) ?? ""
        guard let urlText = Self.firstURL(in: text),
              urlText != lastOfferedClipboardText else { return }

        lastOfferedClipboardText = urlText
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "剪贴板"
        viewModel.offerCompanionClipboard(
            text: urlText,
            sourceApp: frontmostApp == "ChatBot" ? "剪贴板" : frontmostApp,
            capturedAt: Date()
        )
    }

    private static func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        let raw = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return raw
    }

    private func makePanel() -> NSPanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 390),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onEscape = { [weak self] in self?.closePanel() }
        panel.title = "快速捕获"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: QuickCaptureView(
                state: state,
                onOCR: { [weak self] in self?.recognizeClipboardImage() },
                onSubmit: { [weak self] in self?.submitQuickAction() },
                onCancel: { [weak self] in self?.closePanel() }
            )
        )
        return panel
    }

    nonisolated private static func recognizeText(in image: NSImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return ""
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }

            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    private func registerHotKey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr,
                  hotKeyID.signature == QuickCaptureManager.hotKeyID.signature,
                  hotKeyID.id == QuickCaptureManager.hotKeyID.id else {
                return noErr
            }
            Task { @MainActor in
                QuickCaptureManager.shared.showFromClipboard()
            }
            return noErr
        }, 1, &eventSpec, nil, &eventHandler)

        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

struct QuickCaptureView: View {
    @ObservedObject var state: QuickCaptureState
    let onOCR: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private var canSubmit: Bool {
        !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            editor
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 600, height: 390)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.34), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 34, x: 0, y: 18)
        .onChange(of: state.mode) { _, _ in
            state.status = ""
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconTint.opacity(0.9))
                Image(systemName: state.mode.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    pill(state.sourceApp.isEmpty ? "剪贴板" : state.sourceApp, icon: "app.connected.to.app.below.fill")
                    pill("⌥Space", icon: "keyboard")
                }
            }

            Spacer()

            Picker("模式", selection: $state.mode) {
                ForEach(QuickCaptureMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.iconName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $state.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(14)

            if state.text.isEmpty {
                Text(placeholderText)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.white.opacity(0.045))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if state.status.isEmpty {
                Label(footerText, systemImage: footerIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(state.status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onOCR()
            } label: {
                Label("识别截图", systemImage: "text.viewfinder")
            }
            .help("识别剪贴板中的截图文字")

            Button("取消") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                onSubmit()
            } label: {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func pill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }

    private var iconTint: Color {
        switch state.mode {
        case .chat: return .accentColor
        case .schedule: return .blue
        }
    }

    private var headerTitle: String {
        switch state.mode {
        case .chat: return "快速 Chat"
        case .schedule: return "快速日程"
        }
    }

    private var placeholderText: String {
        switch state.mode {
        case .chat: return "输入要发送给当前对话的消息。"
        case .schedule: return "粘贴聊天通知或输入要保存的日程线索。"
        }
    }

    private var footerText: String {
        switch state.mode {
        case .chat: return "发送到当前对话。"
        case .schedule: return "保存到中转站。"
        }
    }

    private var footerIcon: String {
        switch state.mode {
        case .chat: return "bubble.left.and.bubble.right"
        case .schedule: return "tray.full"
        }
    }

    private var primaryButtonTitle: String {
        switch state.mode {
        case .chat: return "发送"
        case .schedule: return "保存"
        }
    }

    private var primaryButtonIcon: String {
        switch state.mode {
        case .chat: return "paperplane.fill"
        case .schedule: return "tray.and.arrow.down.fill"
        }
    }
}

private extension String {
    var fourCharCodeValue: FourCharCode {
        utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}

extension Notification.Name {
    static let openChat = Notification.Name("ChatBotOpenChat")
    static let openScheduleAgent = Notification.Name("ChatBotOpenScheduleAgent")
}
