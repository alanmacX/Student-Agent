import SwiftUI

struct MessageBubble: View {
    let message: Message
    @State private var hovered = false
    @State private var copied = false
    @State private var reasoningExpanded = false
    @State private var appeared = false
    @State private var renderedMarkdown: AttributedString?

    private var isUser: Bool { message.role == .user }
    private var reasoningText: String {
        message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
                bubbleStack
                if let usage = message.usage, usage.totalTokens > 0 {
                    MessageUsageView(usage: usage)
                        .padding(.leading, isUser ? 0 : 4)
                        .padding(.trailing, isUser ? 4 : 0)
                }
            }
            // Slide-in + fade entrance — bouncier on user messages
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .scaleEffect(appeared ? 1 : 0.96, anchor: isUser ? .bottomTrailing : .bottomLeading)
            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal)
        .onHover { hovered = $0 }
        .onAppear {
            withAnimation(isUser ? .bouncySpring.delay(0.02) : .uiSpring.delay(0.02)) {
                appeared = true
            }
        }
        .task(id: message.content) {
            guard !isUser else { return }
            let content = message.content.isEmpty ? " " : message.content
            let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .full)
            )
            renderedMarkdown = attributed
        }
    }

    // MARK: - Bubble

    private var bubbleStack: some View {
        ZStack(alignment: isUser ? .topTrailing : .topLeading) {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser && !reasoningText.isEmpty {
                    reasoningPanel
                }
                messageContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBG)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius:     isUser ? 18 : 4,
                        bottomLeadingRadius:  18,
                        bottomTrailingRadius: isUser ? 4 : 18,
                        topTrailingRadius:    18))
                if !isUser, let payload = message.chatListPayload {
                    ChatNativeListView(payload: payload)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if !isUser, let payload = message.schedulePayload {
                    SchedulePayloadView(payload: payload)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }

            if hovered {
                copyButton
                    .offset(x: isUser ? 8 : -8, y: -12)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.quickSpring, value: hovered)
    }

    private var bubbleBG: some ShapeStyle {
        if isUser {
            return AnyShapeStyle(Color.accentColor)
        } else {
            return AnyShapeStyle(Color(.controlBackgroundColor))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var messageContent: some View {
        if isUser {
            Text(message.content.isEmpty ? " " : message.content)
                .textSelection(.enabled)
        } else if let attributed = renderedMarkdown {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(message.content.isEmpty ? " " : message.content)
                .textSelection(.enabled)
        }
    }

    // MARK: - Reasoning panel

    private var reasoningPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.quickSpring) { reasoningExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.purple)
                        // Pulse while loading / first time shown
                        .symbolEffect(.pulse, isActive: !appeared)
                    Text("思考过程")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(reasoningExpanded ? .degrees(-180) : .zero)
                        .animation(.quickSpring, value: reasoningExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if reasoningExpanded {
                Divider().opacity(0.4)
                ScrollView {
                    Text(reasoningText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 200)
                .transition(.push(from: .top).combined(with: .opacity))
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.purple.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: - Copy button

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
            withAnimation(.bouncySpring) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.quickSpring) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: copied)
                .frame(width: 28, height: 28)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(copied ? "已复制" : "复制消息")
    }
}

private struct ChatNativeListView: View {
    let payload: ChatListPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.title)
                        .font(.system(size: 13, weight: .bold))
                    if let subtitle = payload.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Text("\(payload.items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            VStack(spacing: 0) {
                ForEach(payload.items) { item in
                    ChatNativeListRow(item: item)
                    if item.id != payload.items.last?.id {
                        Divider().padding(.leading, 24)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch payload.style {
        case "todo": return "checklist"
        case "ranked": return "list.number"
        default: return "list.bullet.rectangle"
        }
    }
}

private struct ChatNativeListRow: View {
    let item: ChatListItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: leadingIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(priorityColor)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .strikethrough(item.isDone == true)
                        .foregroundStyle(item.isDone == true ? .secondary : .primary)
                        .lineLimit(2)
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(priorityColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(priorityColor.opacity(0.12), in: Capsule())
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private var leadingIcon: String {
        if item.isDone == true { return "checkmark.circle.fill" }
        switch item.priority {
        case "high": return "exclamationmark.circle.fill"
        case "low": return "circle"
        default: return "circle.fill"
        }
    }

    private var priorityColor: Color {
        switch item.priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .secondary
        default: return .accentColor
        }
    }
}
