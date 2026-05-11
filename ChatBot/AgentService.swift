import Foundation

// MARK: - Agent message types

struct AgentMsg {
    enum Role { case system, user, assistant, tool }
    var role: Role
    var content: String?
    var reasoningContent: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?    // for tool results
    var toolName: String?      // for tool results (Anthropic)
}

struct ToolCall {
    let id: String
    let name: String
    let argsJSON: String

    var args: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
    }
}

private func jsonString(from value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return string
}

struct AgentResponse {
    var text: String?
    var reasoningContent: String?
    var toolCalls: [ToolCall]?
    var done: Bool { toolCalls == nil || toolCalls!.isEmpty }
}

// MARK: - Tool definition

struct AgentTool {
    let name: String
    let description: String
    let parameters: [String: Any]   // JSON Schema object

    func toOpenAI() -> [String: Any] {
        ["type": "function", "function": [
            "name": name,
            "description": description,
            "parameters": parameters
        ] as [String: Any]]
    }

    func toAnthropic() -> [String: Any] {
        ["name": name, "description": description, "input_schema": parameters]
    }
}

// MARK: - OpenAI-compatible (covers DeepSeek, Xiaomi MiMo, etc.)

func openAIAgentComplete(
    messages: [AgentMsg],
    tools: [AgentTool],
    model: String, apiKey: String, baseURL: String,
    thinkingBudget: Int = 0
) async throws -> AgentResponse {
    var req = URLRequest(url: try agentEndpointURL(baseURL: baseURL, path: "/v1/chat/completions"))
    req.httpMethod = "POST"
    setAgentOpenAICompatibleAuth(apiKey: apiKey, baseURL: baseURL, request: &req)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let capability = agentModelThinkingCapability(model: model, baseURL: baseURL)
    let thinkingOn = thinkingBudget > 0

    var body: [String: Any] = [
        "model": model,
        "messages": messages.map { openAIMsg($0) }
    ]

    switch capability {
    case .deepseekReasoner:
        // deepseek-reasoner activates CoT automatically via model name.
        // It does NOT support Function Calling — omit tools entirely.
        // max_tokens controls total output (CoT + answer), default 32 K.
        body["max_tokens"] = 32768

    case .mimoToggle:
        // MiMO: toggle thinking via chat_template_kwargs.
        // Function Calling is unreliable when thinking is enabled — omit tools in that case.
        if thinkingOn {
            body["chat_template_kwargs"] = ["enable_thinking": true]
        } else {
            body["chat_template_kwargs"] = ["enable_thinking": false]
            if !tools.isEmpty {
                body["tools"] = tools.map { $0.toOpenAI() }
                body["tool_choice"] = "auto"
            }
        }

    case .none:
        // Standard OpenAI-compatible. Pass tools normally.
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toOpenAI() }
            body["tool_choice"] = "auto"
        }
    }

    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    var (data, resp) = try await URLSession.shared.data(for: req)
    if (resp as? HTTPURLResponse)?.statusCode == 401, isAgentXiaomiMimoBaseURL(baseURL), !apiKey.isEmpty {
        var retry = req
        setAgentOpenAICompatibleBearerAuth(apiKey: apiKey, request: &retry)
        (data, resp) = try await URLSession.shared.data(for: retry)
    }
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let msg = choices.first?["message"] as? [String: Any]
    else { throw APIError.invalidResponse }

    var res = AgentResponse()
    res.text = msg["content"] as? String
    res.reasoningContent = msg["reasoning_content"] as? String
    if let tcs = msg["tool_calls"] as? [[String: Any]] {
        res.toolCalls = tcs.compactMap { tc -> ToolCall? in
            guard let id = tc["id"] as? String,
                  let fn = tc["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return nil }
            let args = jsonString(from: fn["arguments"]) ?? "{}"
            return ToolCall(id: id, name: name, argsJSON: args)
        }
    }
    return res
}


// MARK: - Model thinking capability detection

/// Describes how a given model activates extended thinking.
enum AgentModelThinkingCapability {
    /// Standard OpenAI-compatible model with no thinking support.
    case none
    /// deepseek-reasoner / R1: thinking activates automatically via model name.
    /// Function Calling is NOT supported — tools must be omitted for these models.
    case deepseekReasoner
    /// Xiaomi MiMo: toggle via chat_template_kwargs {"enable_thinking": bool}.
    /// Function Calling is unreliable when thinking is enabled.
    case mimoToggle
    // Anthropic extended thinking is handled separately in anthropicAgentComplete.
}

func agentModelThinkingCapability(model: String, baseURL: String) -> AgentModelThinkingCapability {
    if isAgentXiaomiMimoBaseURL(baseURL) { return .mimoToggle }
    let m = model.lowercased()
    if m.contains("deepseek-reasoner") || m.hasSuffix("-r1") ||
       m.contains("-r1-") || m == "r1" { return .deepseekReasoner }
    return .none
}

/// Returns whether this model supports tool/function calling.
/// Call this before deciding whether to pass tools in a request.
func agentModelSupportsToolCalling(model: String, baseURL: String, thinkingEnabled: Bool) -> Bool {
    switch agentModelThinkingCapability(model: model, baseURL: baseURL) {
    case .deepseekReasoner: return false
    case .mimoToggle:       return !thinkingEnabled
    case .none:             return true
    }
}

private func isAgentXiaomiMimoBaseURL(_ baseURL: String) -> Bool {
    baseURL.lowercased().contains("xiaomimimo.com")
}

private func agentEndpointURL(baseURL: String, path: String) throws -> URL {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    var endpointPath = path
    if base.lowercased().hasSuffix("/v1"), endpointPath.hasPrefix("/v1/") {
        endpointPath.removeFirst("/v1".count)
    }
    guard let url = URL(string: base + endpointPath) else {
        throw APIError.invalidResponse
    }
    return url
}

private func setAgentOpenAICompatibleAuth(apiKey: String, baseURL: String, request: inout URLRequest) {
    let key = normalizedAgentOpenAICompatibleAPIKey(apiKey)
    guard !key.isEmpty else { return }
    if isAgentXiaomiMimoBaseURL(baseURL) {
        request.setValue(key, forHTTPHeaderField: "api-key")
    } else {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

private func setAgentOpenAICompatibleBearerAuth(apiKey: String, request: inout URLRequest) {
    let key = normalizedAgentOpenAICompatibleAPIKey(apiKey)
    guard !key.isEmpty else { return }
    request.setValue(nil, forHTTPHeaderField: "api-key")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
}

private func normalizedAgentOpenAICompatibleAPIKey(_ apiKey: String) -> String {
    var key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if let firstLine = key.split(whereSeparator: \.isNewline).first {
        key = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var changed = true
    while changed {
        changed = false
        let lower = key.lowercased()
        if lower.hasPrefix("authorization:") {
            key = String(key.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
        } else if lower.hasPrefix("api-key:") {
            key = String(key.dropFirst("api-key:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
        } else if lower.hasPrefix("bearer ") {
            key = String(key.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
        }
    }
    return key
}

private func openAIMsg(_ m: AgentMsg) -> [String: Any] {
    var d: [String: Any]
    switch m.role {
    case .system:    d = ["role": "system"]
    case .user:      d = ["role": "user"]
    case .assistant: d = ["role": "assistant"]
    case .tool:      d = ["role": "tool"]
    }
    if let c = m.content { d["content"] = c }
    if let reasoning = m.reasoningContent, !reasoning.isEmpty {
        d["reasoning_content"] = reasoning
    }
    if let tc = m.toolCalls, !tc.isEmpty {
        d["tool_calls"] = tc.map {
            ["id": $0.id, "type": "function",
             "function": ["name": $0.name, "arguments": $0.argsJSON] as [String: Any]] as [String: Any]
        }
    }
    if let tcID = m.toolCallID { d["tool_call_id"] = tcID }
    return d
}

// MARK: - Anthropic

func anthropicAgentComplete(
    messages: [AgentMsg],
    tools: [AgentTool],
    model: String, apiKey: String, baseURL: String,
    thinkingBudget: Int = 0
) async throws -> AgentResponse {
    var req = URLRequest(url: URL(string: baseURL + "/v1/messages")!)
    req.httpMethod = "POST"
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let sysMsg = messages.first { $0.role == .system }?.content ?? ""
    let nonSys = messages.filter { $0.role != .system }

    // When thinking is enabled, max_tokens must exceed budget_tokens.
    let maxTokens = thinkingBudget > 0 ? max(4096, thinkingBudget + 1024) : 4096
    var body: [String: Any] = [
        "model": model, "max_tokens": maxTokens,
        "messages": nonSys.map { anthropicMsg($0) }
    ]
    if thinkingBudget > 0 {
        body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
    }
    if !tools.isEmpty {
        body["tools"] = tools.map { $0.toAnthropic() }
    }
    if !sysMsg.isEmpty { body["system"] = sysMsg }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = json["content"] as? [[String: Any]]
    else { throw APIError.invalidResponse }

    var res = AgentResponse()
    var toolCalls: [ToolCall] = []

    for block in content {
        switch block["type"] as? String {
        case "thinking":
            // Extended thinking block — surface as reasoningContent
            if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                res.reasoningContent = (res.reasoningContent ?? "") + thinking
            }
        case "text":
            res.text = (res.text ?? "") + (block["text"] as? String ?? "")
        case "tool_use":
            guard let id   = block["id"]   as? String,
                  let name = block["name"] as? String,
                  let inp  = block["input"] as? [String: Any],
                  let argsData = try? JSONSerialization.data(withJSONObject: inp),
                  let argsStr  = String(data: argsData, encoding: .utf8)
            else { continue }
            toolCalls.append(ToolCall(id: id, name: name, argsJSON: argsStr))
        default: break
        }
    }
    if !toolCalls.isEmpty { res.toolCalls = toolCalls }
    return res
}

private func anthropicMsg(_ m: AgentMsg) -> [String: Any] {
    switch m.role {
    case .user:
        return ["role": "user", "content": m.content ?? ""]
    case .assistant:
        var content: [[String: Any]] = []
        if let text = m.content, !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        if let tcs = m.toolCalls {
            for tc in tcs {
                let inp = (try? JSONSerialization.jsonObject(with: Data(tc.argsJSON.utf8))) ?? [:]
                content.append(["type": "tool_use", "id": tc.id, "name": tc.name, "input": inp])
            }
        }
        return ["role": "assistant", "content": content]
    case .tool:
        return ["role": "user", "content": [
            ["type": "tool_result",
             "tool_use_id": m.toolCallID ?? "",
             "content": m.content ?? ""]
        ]]
    default:
        return ["role": "user", "content": m.content ?? ""]
    }
}

// MARK: - Gemini

func geminiAgentComplete(
    messages: [AgentMsg],
    tools: [AgentTool],
    model: String, apiKey: String, baseURL: String
) async throws -> AgentResponse {
    let urlStr = "\(baseURL)/v1beta/models/\(model):generateContent?key=\(apiKey)"
    var req = URLRequest(url: URL(string: urlStr)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let sysMsg = messages.first { $0.role == .system }?.content
    let nonSys = messages.filter { $0.role != .system }

    let functionDecls = tools.map { t -> [String: Any] in
        ["name": t.name, "description": t.description, "parameters": t.parameters]
    }

    var body: [String: Any] = [
        "contents": nonSys.map { geminiMsg($0) }
    ]
    if !functionDecls.isEmpty {
        body["tools"] = [["function_declarations": functionDecls]]
    }
    if let sys = sysMsg, !sys.isEmpty {
        body["system_instruction"] = ["parts": [["text": sys]]]
    }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
    }
    guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cands    = json["candidates"] as? [[String: Any]],
          let content  = cands.first?["content"] as? [String: Any],
          let parts    = content["parts"] as? [[String: Any]]
    else { throw APIError.invalidResponse }

    var res = AgentResponse()
    var toolCalls: [ToolCall] = []

    for part in parts {
        if let text = part["text"] as? String {
            res.text = (res.text ?? "") + text
        } else if let fc = part["functionCall"] as? [String: Any],
                  let name = fc["name"] as? String,
                  let args = fc["args"] as? [String: Any],
                  let argsData = try? JSONSerialization.data(withJSONObject: args),
                  let argsStr  = String(data: argsData, encoding: .utf8) {
            toolCalls.append(ToolCall(id: UUID().uuidString, name: name, argsJSON: argsStr))
        }
    }
    if !toolCalls.isEmpty { res.toolCalls = toolCalls }
    return res
}

private func geminiMsg(_ m: AgentMsg) -> [String: Any] {
    let role = m.role == .user || m.role == .tool ? "user" : "model"
    var parts: [[String: Any]] = []
    if let c = m.content { parts.append(["text": c]) }
    if let tcs = m.toolCalls {
        for tc in tcs {
            let args = (try? JSONSerialization.jsonObject(with: Data(tc.argsJSON.utf8))) ?? [:]
            parts.append(["functionCall": ["name": tc.name, "args": args]])
        }
    }
    if m.role == .tool, let name = m.toolName, let result = m.content {
        parts = [["functionResponse": ["name": name, "response": ["output": result]]]]
    }
    return ["role": role, "parts": parts]
}

// MARK: - Dispatch

func agentComplete(
    messages: [AgentMsg],
    tools: [AgentTool],
    provider: Provider, model: String, apiKey: String,
    thinkingBudget: Int = 0
) async throws -> AgentResponse {
    switch provider.apiType {
    case .openAI, .openAICompatible, .xiaomiMimo:
        return try await openAIAgentComplete(messages: messages, tools: tools, model: model, apiKey: apiKey, baseURL: provider.baseURL, thinkingBudget: thinkingBudget)
    case .anthropic:
        return try await anthropicAgentComplete(messages: messages, tools: tools, model: model, apiKey: apiKey, baseURL: provider.baseURL, thinkingBudget: thinkingBudget)
    case .gemini:
        return try await geminiAgentComplete(messages: messages, tools: tools, model: model, apiKey: apiKey, baseURL: provider.baseURL)
    }
}
