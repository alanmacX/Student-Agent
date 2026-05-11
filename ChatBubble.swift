// ChatBubble.swift
// Glass UI chat bubbles for macOS learning assistant
// Requires macOS 14+ / SwiftUI
//
// Components:
//   UserBubble       — right-aligned, blue glass, asymmetric radius 16-16-4-16
//   AIBubble         — left-aligned, white glass, asymmetric radius 4-16-16-16
//   ThinkingBlock    — left-aligned, ultra-thin glass, collapsible, border-left accent
//   StreamingIndicator — animated three-dot pulse
//   MessageRow       — composes all three with correct layout + width limits
//   ChatView         — scrollable demo container

import SwiftUI

// MARK: - Design Tokens

private enum G {
    // Colors
    static let userTint     = Color(red: 10/255, green: 132/255, blue: 255/255)
    static let aiText       = Color.white.opacity(0.88)
    static let thinkText    = Color.white.opacity(0.45)
    static let thinkLabel   = Color.white.opacity(0.30)
    static let thinkAccent  = Color.white.opacity(0.20)  // border-left
    static let edgeBorder   = Color.white.opacity(0.14)
    static let specular     = Color.white.opacity(0.18)  // inset top highlight

    // Tint opacities (over material)
    static let userTintOpacity: Double   = 0.75
    static let aiTintOpacity: Double     = 0.12
    static let thinkTintOpacity: Double  = 0.04

    // Max width fractions
    static let userMaxFrac: CGFloat     = 0.70
    static let aiMaxFrac: CGFloat       = 0.75
    static let thinkMaxFrac: CGFloat    = 0.78

    // Thinking block max visible height before scroll
    static let thinkMaxHeight: CGFloat  = 160

    // Padding
    static let bubbleH: CGFloat = 12  // horizontal
    static let bubbleV: CGFloat = 8   // vertical
}

// MARK: - Bubble Shapes

/// User bubble: top-left 16, top-right 16, bottom-right 4, bottom-left 16
private struct UserBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 16, small: CGFloat = 4
        var p = Path()
        p.move(to: .init(x: rect.minX + big, y: rect.minY))
        p.addLine(to: .init(x: rect.maxX - big, y: rect.minY))
        p.addArc(center: .init(x: rect.maxX - big, y: rect.minY + big),
                 radius: big, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: .init(x: rect.maxX, y: rect.maxY - small))
        p.addArc(center: .init(x: rect.maxX - small, y: rect.maxY - small),
                 radius: small, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: .init(x: rect.minX + big, y: rect.maxY))
        p.addArc(center: .init(x: rect.minX + big, y: rect.maxY - big),
                 radius: big, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: .init(x: rect.minX, y: rect.minY + big))
        p.addArc(center: .init(x: rect.minX + big, y: rect.minY + big),
                 radius: big, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// AI bubble: top-left 4, top-right 16, bottom-right 16, bottom-left 16
private struct AIBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 16, small: CGFloat = 4
        var p = Path()
        p.move(to: .init(x: rect.minX + small, y: rect.minY))
        p.addLine(to: .init(x: rect.maxX - big, y: rect.minY))
        p.addArc(center: .init(x: rect.maxX - big, y: rect.minY + big),
                 radius: big, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: .init(x: rect.maxX, y: rect.maxY - big))
        p.addArc(center: .init(x: rect.maxX - big, y: rect.maxY - big),
                 radius: big, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: .init(x: rect.minX + big, y: rect.maxY))
        p.addArc(center: .init(x: rect.minX + big, y: rect.maxY - big),
                 radius: big, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: .init(x: rect.minX, y: rect.minY + small))
        p.addArc(center: .init(x: rect.minX + small, y: rect.minY + small),
                 radius: small, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Thinking block: top-left 0, top-right 10, bottom-right 10, bottom-left 0
private struct ThinkingShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 10
        var p = Path()
        p.move(to: .init(x: rect.minX, y: rect.minY))
        p.addLine(to: .init(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: .init(x: rect.maxX - r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: .init(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: .init(x: rect.maxX - r, y: rect.maxY - r),
                 radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: .init(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Specular Overlay

/// Thin top-edge highlight simulating glass specular reflection
private struct SpecularOverlay: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.white.opacity(0.18)
                .frame(height: 0.5)
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 10)
            Spacer()
        }
    }
}

// MARK: - UserBubble

struct UserBubble: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Text(text)
            .font(.callout)                          // font-body: 13pt / 400
            .foregroundColor(.white)
            .padding(.horizontal, G.bubbleH)
            .padding(.vertical, G.bubbleV)
            .background {
                ZStack {
                    // Glass base
                    G.userTint
                        .opacity(G.userTintOpacity)
                        .background(.ultraThinMaterial)
                    // Specular
                    SpecularOverlay()
                }
            }
            .clipShape(UserBubbleShape())
            .overlay {
                UserBubbleShape()
                    .strokeBorder(G.userTint.opacity(0.90), lineWidth: 0.5)
            }
            // Entry animation
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 12)
            .onAppear {
                withAnimation(
                    reduceMotion
                        ? .linear(duration: 0)
                        : .spring(response: 0.18, dampingFraction: 0.82)
                ) { appeared = true }
            }
    }
}

// MARK: - AIBubble

struct AIBubble: View {
    let text: String
    var isStreaming: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)                      // font-body: 13pt / 400
                .foregroundColor(G.aiText)
                .padding(.horizontal, G.bubbleH)
                .padding(.vertical, G.bubbleV)
                .background {
                    ZStack {
                        Color.white
                            .opacity(G.aiTintOpacity)
                            .background(.regularMaterial)
                        SpecularOverlay()
                    }
                }
                .clipShape(AIBubbleShape())
                .overlay {
                    AIBubbleShape()
                        .strokeBorder(G.edgeBorder, lineWidth: 0.5)
                }

            if isStreaming {
                StreamingIndicator()
                    .padding(.leading, G.bubbleH)
                    .transition(.opacity)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -12)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .linear(duration: 0)
                    : .spring(response: 0.22, dampingFraction: 0.84)
            ) { appeared = true }
        }
    }
}

// MARK: - ThinkingBlock

struct ThinkingBlock: View {
    let content: String
    /// True when previous (non-last) blocks are hidden
    var isCollapsed: Bool = false
    var collapsedCount: Int = 0
    var onToggle: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedRow
            } else {
                expandedBlock
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .linear(duration: 0)
                    : .easeOut(duration: 0.16)
            ) { appeared = true }
        }
    }

    // MARK: Expanded

    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row
            HStack {
                Text("思考过程")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(G.thinkLabel)
                    .kerning(0.8)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    withAnimation(
                        reduceMotion
                            ? .linear(duration: 0)
                            : .easeIn(duration: 0.14)
                    ) { onToggle?() }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(G.thinkLabel)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("折叠思考过程")
            }

            // Scrollable content (capped at G.thinkMaxHeight)
            ScrollView {
                Text(content)
                    .font(.footnote)                 // font-body-sec: 12pt / 400
                    .foregroundColor(G.thinkText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: G.thinkMaxHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            ZStack {
                Color.white
                    .opacity(G.thinkTintOpacity)
                    .background(.thinMaterial)
                // Specular
                VStack(spacing: 0) {
                    Color.white.opacity(0.10).frame(height: 0.5)
                    Spacer()
                }
            }
        }
        .clipShape(ThinkingShape())
        .overlay {
            ThinkingShape()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        // Left accent border
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(G.thinkAccent)
                .frame(width: 1.5)
        }
    }

    // MARK: Collapsed

    private var collapsedRow: some View {
        Button {
            withAnimation(
                reduceMotion
                    ? .linear(duration: 0)
                    : .spring(response: 0.22, dampingFraction: 0.84)
            ) { onToggle?() }
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(G.thinkAccent)
                    .frame(width: 1.5, height: 14)

                Text("已折叠 \(collapsedCount) 段思考")
                    .font(.footnote)
                    .foregroundColor(G.thinkLabel)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(G.thinkLabel)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开 \(collapsedCount) 段思考过程")
    }
}

// MARK: - StreamingIndicator

struct StreamingIndicator: View {
    @State private var active: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(active == i ? 0.70 : 0.22))
                    .frame(width: 5, height: 5)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.16),
                        value: active
                    )
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                active = (active + 1) % 3
            }
        }
        .accessibilityLabel("AI 正在回复")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    var thinking: String? = nil
    var isStreaming: Bool = false

    enum Role { case user, assistant }
}

// MARK: - MessageRow

/// Lays out a single message, composing bubbles + thinking block.
/// Width limits (70 / 75 / 78%) are enforced via containerRelativeFrame.
struct MessageRow: View {
    let message: ChatMessage

    /// Tracks collapse state for the thinking block on this message.
    /// In production, drive this from the view model.
    @State private var thinkingCollapsed = false

    var body: some View {
        switch message.role {

        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                UserBubble(text: message.content)
                    .containerRelativeFrame(.horizontal) { w, _ in w * G.userMaxFrac }
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .assistant:
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    if let thinking = message.thinking {
                        ThinkingBlock(
                            content: thinking,
                            isCollapsed: thinkingCollapsed,
                            collapsedCount: 1,
                            onToggle: { thinkingCollapsed.toggle() }
                        )
                        .containerRelativeFrame(.horizontal) { w, _ in w * G.thinkMaxFrac }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    AIBubble(text: message.content, isStreaming: message.isStreaming)
                        .containerRelativeFrame(.horizontal) { w, _ in w * G.aiMaxFrac }
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Chat View

/// Demo container — dark background matching app bg token #0D0D10
struct ChatView: View {
    @State private var messages: [ChatMessage] = [
        ChatMessage(
            role: .user,
            content: "并不是做脚本，而是接入自己设计的 agent 做日程管理之类的"
        ),
        ChatMessage(
            role: .assistant,
            content: "几个建议供你参考：首先，检查学校教务系统是否有官方日历订阅功能（如 iCal 格式导出）。如果有，直接订阅是最合规、省事的方式。如果没有，你可以通过抓包获取作业列表接口，然后写一个工具函数供 agent 调用。",
            thinking: "你的需求是接入自定义 Agent 进行日程管理（如同步作业），这比刷课更像个人数据整合，风险确实低很多。控制好频率，一天查两三次足够模拟正常查看；避免触发风控 Token 有效期机制，需要处理刷新逻辑。"
        ),
        ChatMessage(
            role: .user,
            content: "还有什么作业？"
        ),
        ChatMessage(
            role: .assistant,
            content: "这次查到的结果和之前一致，没有新增作业。",
            isStreaming: false
        ),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { msg in
                        MessageRow(message: msg)
                            .padding(.horizontal, 20)
                            .id(msg.id)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .background(Color(red: 13/255, green: 13/255, blue: 16/255))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview("Chat — Dark") {
    ChatView()
        .frame(width: 680, height: 600)
}

#Preview("Bubbles — Unit") {
    VStack(alignment: .leading, spacing: 16) {
        UserBubble(text: "并不是做脚本，而是接入自己设计的 agent 做日程管理之类的")
        ThinkingBlock(
            content: "你的需求是接入自定义 Agent 进行日程管理，这比刷课更像个人数据整合，风险确实低很多。",
            isCollapsed: false
        )
        AIBubble(text: "几个建议供你参考：首先检查学校教务系统是否有官方日历订阅功能。")
        AIBubble(text: "正在思考…", isStreaming: true)
        ThinkingBlock(
            content: "",
            isCollapsed: true,
            collapsedCount: 2
        )
    }
    .padding(24)
    .frame(width: 600)
    .background(Color(red: 13/255, green: 13/255, blue: 16/255))
    .preferredColorScheme(.dark)
}
