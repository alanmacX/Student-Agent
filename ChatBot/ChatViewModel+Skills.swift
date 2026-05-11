import Foundation
import SwiftUI

extension ChatViewModel {
    // MARK: - Skills Management

    func addChatSkill(name: String, description: String, instructions: String, isEnabled: Bool = true) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDescription.isEmpty, !trimmedInstructions.isEmpty else { return }
        guard isValidAgentSkillName(trimmedName) else {
            errorMessage = "Skill name 必须是小写字母、数字或单连字符"
            return
        }
        chatSkills.append(ChatSkill(
            name: trimmedName,
            description: trimmedDescription,
            instructions: trimmedInstructions,
            isEnabled: isEnabled
        ))
        saveSettings()
    }

    func importChatSkillFolder(from url: URL) async {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            let skillURL = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillURL.path) else {
                throw APIError.httpError(400, "Skill 文件夹必须包含 SKILL.md")
            }

            let text: String
            if let utf8 = try? String(contentsOf: skillURL, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: skillURL)
            }

            var skill = try parseAgentSkillMarkdown(text, sourceName: url.lastPathComponent)
            skill.scripts = try loadSkillScripts(from: url)
            chatSkills.removeAll { $0.name == skill.name }
            chatSkills.append(skill)
            saveSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateChatSkill(_ skill: ChatSkill) {
        guard let i = chatSkills.firstIndex(where: { $0.id == skill.id }) else { return }
        guard isValidAgentSkillName(skill.name) else {
            errorMessage = "Skill name 必须是小写字母、数字或单连字符"
            return
        }
        chatSkills[i] = skill
        saveSettings()
    }

    func deleteChatSkill(_ skill: ChatSkill) {
        chatSkills.removeAll { $0.id == skill.id }
        saveSettings()
    }

    func setChatSkill(_ id: UUID, isEnabled: Bool) {
        guard let i = chatSkills.firstIndex(where: { $0.id == id }) else { return }
        chatSkills[i].isEnabled = isEnabled
        saveSettings()
    }

    internal func parseAgentSkillMarkdown(_ text: String, sourceName: String) throws -> ChatSkill {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            throw APIError.httpError(400, "Skill 必须以 YAML frontmatter 开头")
        }
        guard let endRange = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            throw APIError.httpError(400, "Skill 缺少结束 frontmatter 的 ---")
        }

        let frontmatter = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var bodyStart = endRange.upperBound
        if bodyStart < normalized.endIndex, normalized[bodyStart] == "\n" {
            bodyStart = normalized.index(after: bodyStart)
        }
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = parseFlatYAMLFrontmatter(frontmatter)
        guard let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw APIError.httpError(400, "Skill 缺少必需字段 name")
        }
        guard isValidAgentSkillName(name) else {
            throw APIError.httpError(400, "Skill name 必须是 1-64 位小写字母、数字或单连字符")
        }
        if sourceName != "SKILL", !sourceName.isEmpty, sourceName != name {
            throw APIError.httpError(400, "Skill name 需要和父目录名一致：\(name)")
        }
        guard let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            throw APIError.httpError(400, "Skill 缺少必需字段 description")
        }
        guard description.count <= 1024 else {
            throw APIError.httpError(400, "Skill description 不能超过 1024 字符")
        }
        guard !body.isEmpty else {
            throw APIError.httpError(400, "Skill instructions 不能为空")
        }

        return ChatSkill(
            name: name,
            description: description,
            instructions: body,
            license: fields["license"],
            compatibility: fields["compatibility"],
            allowedTools: fields["allowed-tools"],
            isEnabled: true
        )
    }

    private func parseFlatYAMLFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("  "), let currentKey {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                result[currentKey, default: ""].append("\n\(stripYAMLQuotes(continuation))")
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = stripYAMLQuotes(rawValue)
            currentKey = key
        }
        return result
    }

    internal func loadSkillScripts(from skillFolder: URL) throws -> [ChatSkillScript] {
        let scriptsURL = skillFolder.appendingPathComponent("scripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        guard let enumerator = FileManager.default.enumerator(
            at: scriptsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var scripts: [ChatSkillScript] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            guard isSupportedSkillScript(fileURL) else { continue }
            guard (values.fileSize ?? 0) <= ChatViewModel.maxSkillScriptBytes else {
                throw APIError.httpError(400, "\(fileURL.lastPathComponent) 超过 256KB，未导入")
            }

            let content: String
            if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
                content = utf8
            } else {
                content = try String(contentsOf: fileURL)
            }
            let relative = fileURL.path
                .replacingOccurrences(of: scriptsURL.path + "/", with: "")
            scripts.append(ChatSkillScript(
                name: fileURL.lastPathComponent,
                relativePath: "scripts/\(relative)",
                language: skillScriptLanguage(fileURL),
                content: content
            ))
        }
        return scripts.sorted { $0.relativePath < $1.relativePath }
    }

    private func isSupportedSkillScript(_ url: URL) -> Bool {
        ["sh", "zsh", "bash", "py", "js", "mjs"].contains(url.pathExtension.lowercased())
    }

    private func skillScriptLanguage(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "py": return "python"
        case "js", "mjs": return "node"
        case "bash": return "bash"
        default: return "shell"
        }
    }

    private func stripYAMLQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    internal func isValidAgentSkillName(_ name: String) -> Bool {
        guard (1...64).contains(name.count),
              !name.hasPrefix("-"),
              !name.hasSuffix("-"),
              !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar == "-" ||
                ("0"..."9").contains(String(scalar)) ||
                ("a"..."z").contains(String(scalar))
        }
    }
}
