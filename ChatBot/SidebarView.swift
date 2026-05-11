import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showNewMenu = false
    @State private var searchText = ""

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return viewModel.conversations }
        return viewModel.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(
            selection: Binding(
                get: { viewModel.selectedConversationID },
                set: { viewModel.selectedConversationID = $0 }
            )
        ) {
            ForEach(filtered) { conv in
                ConversationRow(
                    conversation: conv,
                    provider: viewModel.provider(for: conv.providerID)
                )
                .tag(conv.id)
                .contextMenu {
                    Button("删除", role: .destructive) {
                        withAnimation(.smoothSpring) { viewModel.deleteConversation(conv) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索对话")
        .animation(.smoothSpring, value: filtered.map(\.id))
        .navigationTitle("对话")
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.bouncySpring) { showNewMenu = true }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .symbolEffect(.bounce, value: showNewMenu)
                }
                .help("新建对话")
                .popover(isPresented: $showNewMenu, arrowEdge: .bottom) {
                    NewChatPopover(isPresented: $showNewMenu)
                        .environmentObject(viewModel)
                }
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let provider: Provider
    @State private var hovered = false

    private var relativeTime: String {
        let now = Date()
        let diff = now.timeIntervalSince(conversation.updatedAt)
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        if diff < 604800 { return "\(Int(diff / 86400)) 天前" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: conversation.updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: provider.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: provider.colorHex))
                    .frame(width: 14)
                Text(conversation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text(conversation.model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Subtle hover lift
        .scaleEffect(hovered ? 1.01 : 1.0, anchor: .leading)
        .brightness(hovered ? 0.02 : 0)
        .animation(.quickSpring, value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - New Chat Popover

struct NewChatPopover: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("新建对话")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ForEach(Array(viewModel.allProviders.enumerated()), id: \.element.id) { idx, provider in
                popoverRow(provider: provider)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : -8)
                    .animation(.uiSpring.delay(Double(idx) * 0.04 + 0.05), value: appeared)
            }

            Divider()
                .padding(.vertical, 2)

            Button {
                viewModel.createConversation()
                isPresented = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("默认（当前 Provider）")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
        .frame(width: 230)
        .onAppear {
            withAnimation(.uiSpring) { appeared = true }
        }
    }

    private func popoverRow(provider: Provider) -> some View {
        Button {
            viewModel.createConversation(providerID: provider.id)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: provider.colorHex).opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: provider.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: provider.colorHex))
                }
                Text(provider.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.0001))
    }
}
