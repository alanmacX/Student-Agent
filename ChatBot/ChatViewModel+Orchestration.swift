import Foundation
import SwiftUI

internal struct ChatToolRunResult {
    var content: String
    var listPayload: ChatListPayload?

    init(_ content: String, listPayload: ChatListPayload? = nil) {
        self.content = content
        self.listPayload = listPayload
    }
}

extension ChatViewModel {
    // MARK: - Tool Orchestration

    internal func confirmChatToolCalls(_ calls: [ToolCall], conversationID: UUID) async -> Bool {
        guard !calls.isEmpty else { return true }
        if let continuation = chatToolConfirmationContinuation {
            continuation.resume(returning: false)
            chatToolConfirmationContinuation = nil
        }

        return await withCheckedContinuation { continuation in
            chatToolConfirmationContinuation = continuation
            pendingChatToolConfirmation = ChatToolConfirmation(
                conversationID: conversationID,
                title: calls.count == 1 ? "允许访问本机工具？" : "允许访问 \(calls.count) 个本机工具？",
                detail: "Chat agent 想访问本机备忘录、提醒事项 or 日历来完成这轮回复。",
                tools: calls.map(chatToolConfirmationItem)
            )
        }
    }

    internal func chatToolRequiresConfirmation(_ call: ToolCall) -> Bool {
        if call.name == "search_apple_notes" || call.name == "create_apple_note" {
            return true
        }
        return false
    }

    internal func skippedChatToolReasons(for calls: [ToolCall]) -> [String: String] {
        let maxToolsPerRound = 6
        let maxSubAgentsPerRound = 3
        var reasons: [String: String] = [:]
        var runnableToolCount = 0
        var subAgentCount = 0

        for call in calls {
            if call.name == "delegate_to_subagent" {
                subAgentCount += 1
                if subAgentCount > maxSubAgentsPerRound {
                    reasons[call.id] = "本轮 Sub-agent 已达到 \(maxSubAgentsPerRound) 个上限，请先综合已有子任务结果。"
                    continue
                }
            }

            runnableToolCount += 1
            if runnableToolCount > maxToolsPerRound {
                reasons[call.id] = "本轮工具调用已达到 \(maxToolsPerRound) 个上限，请先基于已有结果继续。"
            }
        }
        return reasons
    }

    func resolveChatToolConfirmation(approved: Bool) {
        pendingChatToolConfirmation = nil
        
        if scheduleConfirmationContinuation != nil {
            resolveScheduleConfirmation(confirmed: approved)
        }
        
        if let continuation = chatToolConfirmationContinuation {
            chatToolConfirmationContinuation = nil
            continuation.resume(returning: approved)
        }
    }

    private func chatToolConfirmationItem(_ call: ToolCall) -> ChatToolConfirmationItem {
        ChatToolConfirmationItem(
            name: call.name,
            title: chatToolDisplayName(call.name),
            detail: chatToolCallSummary(call)
        )
    }

    private func chatToolDisplayName(_ name: String) -> String {
        switch name {
        case "make_list": return "绘制原生列表"
        case "web_search": return "联网搜索"
        case "web_fetch": return "读取网页"
        case "read_pdf": return "读取 PDF"
        case "search_apple_notes": return "搜索 Apple Notes"
        case "create_apple_note": return "创建 Apple Note"
        case "add_shopping_items": return "添加购物项"
        case "list_shopping_items": return "查看购物清单"
        case "complete_shopping_item": return "完成购物项"
        case "delete_shopping_item": return "删除购物项"
        case "run_skill_script": return "运行 Skill 脚本"
        case "delegate_to_subagent": return "派发 Sub-agent"
        default: return name
        }
    }

    private func chatToolCallSummary(_ call: ToolCall) -> String {
        switch call.name {
        case "make_list":
            return stringArg(call.args, "title") ?? "生成一个原生列表 UI"
        case "web_search":
            return stringArg(call.args, "query") ?? "搜索网页"
        case "web_fetch":
            return stringArg(call.args, "url") ?? "读取网页内容"
        case "read_pdf":
            return stringArg(call.args, "path") ?? "读取本地 PDF"
        case "search_apple_notes":
            return stringArg(call.args, "query") ?? "搜索备忘录"
        case "create_apple_note":
            return stringArg(call.args, "title") ?? "创建备忘录"
        case "add_shopping_items":
            return "添加模型解析出的购物项"
        case "list_shopping_items":
            return boolArg(call.args, "include_done") == true ? "查看全部购物项" : "查看未完成购物项"
        case "complete_shopping_item":
            return stringArg(call.args, "title") ?? stringArg(call.args, "id") ?? "完成购物项"
        case "delete_shopping_item":
            return stringArg(call.args, "title") ?? stringArg(call.args, "id") ?? "删除购物项"
        case "run_skill_script":
            let skill = stringArg(call.args, "skill_name") ?? "Skill"
            let script = stringArg(call.args, "script_path") ?? "脚本"
            return "\(skill) / \(script)"
        case "delegate_to_subagent":
            return ChaoxingTextNormalizer.preview(stringArg(call.args, "task") ?? "子任务", limit: 80)
        default:
            return "工具参数已由模型生成"
        }
    }

    internal var runnableChatSkillScripts: [ChatSkill] {
        chatSkills.filter { $0.isEnabled && !$0.scripts.isEmpty }
    }

    internal var hasRunnableChatSkillScripts: Bool {
        !runnableChatSkillScripts.isEmpty
    }

    internal func shouldUseChatTools(for text: String) -> Bool {
        scheduleModeEnabled ||
        pdfToolEnabled ||
        appleNotesToolEnabled ||
        shoppingListToolEnabled ||
        hasRunnableChatSkillScripts ||
        (webAccessEnabled && shouldUseWebTools(for: text))
    }

    private func shouldUseWebTools(for text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") {
            return true
        }
        let triggers = [
            "联网", "搜索", "搜一下", "查一下", "查找", "最新", "最近", "实时", "当前", "现在",
            "新闻", "官网", "网页", "网址", "url", "price", "today", "latest", "current",
            "search", "browse", "web"
        ]
        return triggers.contains { lower.contains($0) }
    }
}
