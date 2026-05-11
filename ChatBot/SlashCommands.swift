import SwiftUI

// MARK: - Model

struct SlashCommand: Identifiable, Equatable {
    enum Kind: Equatable {
        case resetContext
        case clearMessages
        case agentPrompt(String)

        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.resetContext, .resetContext):   return true
            case (.clearMessages, .clearMessages): return true
            case (.agentPrompt(let a), .agentPrompt(let b)): return a == b
            default: return false
            }
        }
    }

    let id: String          // same as trigger
    let trigger: String     // text after "/"
    let label: String       // Chinese display name
    let description: String
    let icon: String        // SF Symbol (circle variant)
    let iconColor: Color
    let kind: Kind
}

// MARK: - Command registry

let allSlashCommands: [SlashCommand] = [
    SlashCommand(
        id: "reset", trigger: "reset", label: "重置上下文",
        description: "Agent 遗忘之前的对话，但消息仍可滚动查看",
        icon: "arrow.counterclockwise.circle.fill", iconColor: .orange,
        kind: .resetContext),
    SlashCommand(
        id: "clear", trigger: "clear", label: "清空对话",
        description: "删除所有显示的消息，彻底重新开始",
        icon: "trash.circle.fill", iconColor: .red,
        kind: .clearMessages),
    SlashCommand(
        id: "today", trigger: "today", label: "今日日程",
        description: "查看今天的日历事件和提醒事项",
        icon: "sun.max.circle.fill", iconColor: .yellow,
        kind: .agentPrompt("请列出今天所有的日历事件和未完成的提醒事项")),
    SlashCommand(
        id: "tomorrow", trigger: "tomorrow", label: "明日日程",
        description: "查看明天的日历事件和提醒事项",
        icon: "sun.horizon.circle.fill", iconColor: .orange,
        kind: .agentPrompt("请列出明天所有的日历事件和提醒事项")),
    SlashCommand(
        id: "week", trigger: "week", label: "本周日程",
        description: "查看本周课表和所有日历事件",
        icon: "calendar.circle.fill", iconColor: .blue,
        kind: .agentPrompt("请列出本周（含今天）所有的课程安排和日历事件")),
    SlashCommand(
        id: "reminders", trigger: "reminders", label: "所有提醒",
        description: "列出全部未完成的提醒事项及截止日期",
        icon: "checklist.circle.fill", iconColor: .green,
        kind: .agentPrompt("请列出所有清单下未完成的提醒事项，包含截止日期")),
    SlashCommand(
        id: "lists", trigger: "lists", label: "清单列表",
        description: "显示所有提醒事项清单及数量",
        icon: "list.bullet.circle.fill", iconColor: .purple,
        kind: .agentPrompt("请列出所有的提醒事项清单，以及每个清单的未完成数量")),
    SlashCommand(
        id: "help", trigger: "help", label: "使用帮助",
        description: "了解 Agent 能做哪些日程操作",
        icon: "questionmark.circle.fill", iconColor: .cyan,
        kind: .agentPrompt("请简单介绍你能帮我做哪些日程管理和提醒事项相关的操作，用简洁的列表说明")),
]

// MARK: - Menu view

struct SlashCommandMenuView: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                commandRow(cmd, isSelected: idx == selectedIndex)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Color(.windowBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 8)
    }

    private func commandRow(_ cmd: SlashCommand, isSelected: Bool) -> some View {
        Button { onSelect(cmd) } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(cmd.iconColor)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("/" + cmd.trigger)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(cmd.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(cmd.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "return")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
