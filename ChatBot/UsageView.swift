import SwiftUI

// MARK: - Per-message usage footer

struct MessageUsageView: View {
    let usage: UsageStats
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Compact summary row
            Button {
                withAnimation(.quickSpring) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                        Text(formatTokens(usage.inputTokens))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        Text(formatTokens(usage.outputTokens))
                    }
                    if let cost = usage.estimatedCostUSD {
                        Text("≈ \(formatCost(cost))")
                            .foregroundStyle(.secondary.opacity(0.75))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .animation(.quickSpring, value: expanded)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            // Expanded detail
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    usageRow("输入 tokens", value: usage.inputTokens)
                    if usage.cacheHitTokens > 0 {
                        usageRow("  ↳ 缓存命中", value: usage.cacheHitTokens, color: .green)
                        usageRow("  ↳ 缓存未命中", value: usage.cacheMissTokens, color: .orange)
                    }
                    usageRow("输出 tokens", value: usage.outputTokens)
                    if usage.reasoningTokens > 0 {
                        usageRow("  ↳ 推理 tokens", value: usage.reasoningTokens, color: .purple)
                    }
                    usageRow("总计 tokens", value: usage.totalTokens, bold: true)
                    if let cost = usage.estimatedCostUSD {
                        Divider().opacity(0.5).padding(.vertical, 2)
                        HStack {
                            Text("预估费用")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatCost(cost))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                        }
                        Text("仅供参考，以实际账单为准")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(9)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .padding(.top, 4)
        .padding(.leading, 2)
    }

    private func usageRow(_ label: String, value: Int, color: Color = .secondary, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: bold ? .semibold : .regular))
                .foregroundStyle(color)
            Spacer()
            Text(formatTokens(value))
                .font(.system(size: 10, weight: bold ? .bold : .medium))
                .foregroundStyle(bold ? .primary : color)
                .monospacedDigit()
        }
    }
}

// MARK: - Conversation total bar

struct ConversationUsageBar: View {
    let usage: UsageStats
    let model: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            HStack(spacing: 2) {
                Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
                Text(formatTokens(usage.inputTokens))
            }
            Text("/").foregroundStyle(.quaternary)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                Text(formatTokens(usage.outputTokens))
            }
            if let cost = usage.estimatedCostUSD, cost > 0 {
                Text("·").foregroundStyle(.quaternary)
                Text("≈ \(formatCost(cost))")
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

// MARK: - Balance sheet

struct BalanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: ChatViewModel
    let provider: Provider
    @State private var balances: [ProviderBalance] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: provider.colorHex).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: provider.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: provider.colorHex))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name)
                        .font(.headline)
                    Text("账户余额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .keyboardShortcut(.cancelAction)
                .help("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Body
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("查询中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.orange)
                        Text("查询失败")
                            .font(.callout.bold())
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if balances.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "creditcard.trianglebadge.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("暂无余额信息")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(balances) { b in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label(b.currency, systemImage: "dollarsign.circle.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .symbolRenderingMode(.hierarchical)
                                        Spacer()
                                    }
                                    balanceRow("总余额", value: b.total, large: true)
                                    Divider().opacity(0.5)
                                    balanceRow("充值余额", value: b.toppedUp)
                                    balanceRow("赠送余额", value: b.granted)
                                }
                                .padding(14)
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.quickSpring, value: loading)
            .animation(.quickSpring, value: error)
        }
        .frame(width: 340, height: 320)
        .task {
            let vm = viewModel
            do {
                balances = try await vm.checkBalance(for: provider)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func balanceRow(_ label: String, value: String, large: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(large ? .callout : .caption)
                .foregroundStyle(large ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(large ? .title2.bold() : .callout)
                .foregroundStyle(large ? .primary : .secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Formatters

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

func formatCost(_ usd: Double) -> String {
    if usd < 0.0001 { return "< $0.0001" }
    if usd < 0.01   { return String(format: "$%.4f", usd) }
    if usd < 1.0    { return String(format: "$%.3f", usd) }
    return String(format: "$%.2f", usd)
}
