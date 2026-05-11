import Foundation

// MARK: - Protocol

protocol ChatServiceProtocol {
    func stream(messages: [Message], model: String, apiKey: String, baseURL: String, thinkingEnabled: Bool) async throws -> AsyncThrowingStream<StreamEvent, Error>
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse, httpError(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let c, let b): return "HTTP \(c): \(b)"
        }
    }
}

// MARK: - OpenAI (and OpenAI-compatible)

struct OpenAIService: ChatServiceProtocol {
    func stream(messages: [Message], model: String, apiKey: String, baseURL: String, thinkingEnabled: Bool) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let isXiaomiMimo = isXiaomiMimoBaseURL(baseURL)
        var req = URLRequest(url: try endpointURL(baseURL: baseURL, path: "/v1/chat/completions"))
        req.httpMethod = "POST"
        setOpenAICompatibleAuth(apiKey: apiKey, baseURL: baseURL, request: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { openAIChatMessage($0) }
        ]
        if isXiaomiMimo {
            body["max_completion_tokens"] = 8192
        } else {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]   // request usage in final chunk
        }
        if thinkingEnabled && shouldSendDeepSeekThinking(model: model, baseURL: baseURL) {
            body["thinking"] = ["type": "enabled"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if isXiaomiMimo {
                        do {
                            try await consumeOpenAICompletion(request: req, continuation: cont)
                        } catch APIError.httpError(401, _) where !apiKey.isEmpty {
                            var retry = req
                            setOpenAICompatibleBearerAuth(apiKey: apiKey, request: &retry)
                            try await consumeOpenAICompletion(request: retry, continuation: cont)
                        }
                        cont.finish()
                        return
                    }

                    func consume(_ request: URLRequest) async throws {
                        let (bytes, resp) = try await URLSession.shared.bytes(for: request)
                        try await checkHTTP(resp, bytes: bytes)
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" { break }
                            guard let d = payload.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                            else { continue }
                            // text chunk
                            if let choices = json["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any] {
                                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                    cont.yield(.reasoning(reasoning))
                                }
                                if let text = delta["content"] as? String, !text.isEmpty {
                                    cont.yield(.text(text))
                                }
                            }
                            // usage chunk (final event where choices is empty)
                            if let u = json["usage"] as? [String: Any] {
                                cont.yield(.usage(parseOpenAIUsage(u)))
                            }
                        }
                    }

                    do {
                        try await consume(req)
                    }
                    cont.finish()
                } catch {
                    if error is CancellationError { cont.finish() }
                    else { cont.finish(throwing: error) }
                }
            }
            cont.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private func openAIChatMessage(_ message: Message) -> [String: Any] {
    [
        "role": message.role.rawValue,
        "content": message.content
    ]
}

private func shouldSendDeepSeekThinking(model: String, baseURL: String) -> Bool {
    let lowerModel = model.lowercased()
    let lowerURL = baseURL.lowercased()
    return lowerURL.contains("deepseek") && lowerModel == "deepseek-chat"
}

private func parseOpenAIUsage(_ u: [String: Any]) -> UsageStats {
    var s = UsageStats()
    s.inputTokens      = u["prompt_tokens"]     as? Int ?? 0
    s.outputTokens     = u["completion_tokens"] as? Int ?? 0
    s.cacheHitTokens   = u["prompt_cache_hit_tokens"]  as? Int ?? 0
    s.cacheMissTokens  = u["prompt_cache_miss_tokens"] as? Int ?? 0
    // OpenAI stores cache info nested in prompt_tokens_details
    if s.cacheHitTokens == 0,
       let details = u["prompt_tokens_details"] as? [String: Any] {
        s.cacheHitTokens  = details["cached_tokens"] as? Int ?? 0
    }
    if let cd = u["completion_tokens_details"] as? [String: Any] {
        s.reasoningTokens = cd["reasoning_tokens"] as? Int ?? 0
    }
    return s
}

private func consumeOpenAICompletion(
    request: URLRequest,
    continuation cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
) async throws {
    let (data, resp) = try await URLSession.shared.data(for: request)
    try checkHTTP(resp, data: data)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any]
    else { throw APIError.invalidResponse }

    if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
        cont.yield(.reasoning(reasoning))
    }
    if let text = message["content"] as? String, !text.isEmpty {
        cont.yield(.text(text))
    }
    if let usage = json["usage"] as? [String: Any] {
        cont.yield(.usage(parseOpenAIUsage(usage)))
    }
}

// MARK: - Anthropic

struct AnthropicService: ChatServiceProtocol {
    func stream(messages: [Message], model: String, apiKey: String, baseURL: String, thinkingEnabled: Bool) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        var req = URLRequest(url: URL(string: baseURL + "/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let nonSys = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": model, "max_tokens": 8096, "stream": true,
            "messages": nonSys.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if let sys = messages.first(where: { $0.role == .system })?.content, !sys.isEmpty {
            body["system"] = sys
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try await checkHTTP(resp, bytes: bytes)
                    var usage = UsageStats()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let d = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        switch json["type"] as? String {
                        case "message_start":
                            if let msg = json["message"] as? [String: Any],
                               let u = msg["usage"] as? [String: Any] {
                                usage.inputTokens     = u["input_tokens"]  as? Int ?? 0
                                usage.cacheHitTokens  = u["cache_read_input_tokens"]     as? Int ?? 0
                                usage.cacheMissTokens = usage.inputTokens - usage.cacheHitTokens
                            }
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                cont.yield(.text(text))
                            }
                        case "message_delta":
                            if let u = json["usage"] as? [String: Any] {
                                usage.outputTokens = u["output_tokens"] as? Int ?? 0
                            }
                        case "message_stop":
                            cont.yield(.usage(usage))
                        default: break
                        }
                    }
                    cont.finish()
                } catch {
                    if error is CancellationError { cont.finish() }
                    else { cont.finish(throwing: error) }
                }
            }
            cont.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Gemini

struct GeminiService: ChatServiceProtocol {
    func stream(messages: [Message], model: String, apiKey: String, baseURL: String, thinkingEnabled: Bool) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let urlStr = "\(baseURL)/v1beta/models/\(model):streamGenerateContent?key=\(apiKey)&alt=sse"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let contents = messages.filter { $0.role != .system }.map { msg -> [String: Any] in
            ["role": msg.role == .user ? "user" : "model", "parts": [["text": msg.content]]]
        }
        var body: [String: Any] = ["contents": contents]
        if let sys = messages.first(where: { $0.role == .system })?.content, !sys.isEmpty {
            body["systemInstruction"] = ["parts": [["text": sys]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try await checkHTTP(resp, bytes: bytes)
                    var lastUsage: UsageStats?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let d = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        if let candidates = json["candidates"] as? [[String: Any]],
                           let content = candidates.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let text = parts.first?["text"] as? String {
                            cont.yield(.text(text))
                        }
                        if let um = json["usageMetadata"] as? [String: Any] {
                            var u = UsageStats()
                            u.inputTokens    = um["promptTokenCount"]     as? Int ?? 0
                            u.outputTokens   = um["candidatesTokenCount"] as? Int ?? 0
                            u.cacheHitTokens = um["cachedContentTokenCount"] as? Int ?? 0
                            lastUsage = u
                        }
                    }
                    if let u = lastUsage { cont.yield(.usage(u)) }
                    cont.finish()
                } catch {
                    if error is CancellationError { cont.finish() }
                    else { cont.finish(throwing: error) }
                }
            }
            cont.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Balance check (OpenAI-compatible /user/balance)

struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfoRaw]
    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}
struct BalanceInfoRaw: Decodable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String
    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance    = "total_balance"
        case grantedBalance  = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

func fetchBalance(baseURL: String, apiKey: String) async throws -> [ProviderBalance] {
    var req = URLRequest(url: URL(string: baseURL + "/user/balance")!)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
    let decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
    return decoded.balanceInfos.map {
        ProviderBalance(currency: $0.currency, total: $0.totalBalance,
                        granted: $0.grantedBalance, toppedUp: $0.toppedUpBalance)
    }
}

// MARK: - API reachability

func checkProviderReachability(provider: Provider, apiKey: String) async -> APIReachabilityResult {
    let startedAt = Date()
    do {
        var request = try reachabilityRequest(provider: provider, apiKey: apiKey)
        request.timeoutInterval = 8

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        let latency = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        guard let http = response as? HTTPURLResponse else {
            return APIReachabilityResult(
                state: .networkIssue,
                statusCode: nil,
                latencyMS: latency,
                message: "没有收到有效 HTTP 响应"
            )
        }

        let bodyHint = String(data: data.prefix(240), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch http.statusCode {
        case 200..<300:
            return APIReachabilityResult(
                state: .reachable,
                statusCode: http.statusCode,
                latencyMS: latency,
                message: "API 可用，\(latency)ms"
            )
        case 401, 403:
            return APIReachabilityResult(
                state: .authIssue,
                statusCode: http.statusCode,
                latencyMS: latency,
                message: "网络可达，但 Key 或权限未通过，HTTP \(http.statusCode)"
            )
        case 404:
            return APIReachabilityResult(
                state: .endpointIssue,
                statusCode: http.statusCode,
                latencyMS: latency,
                message: "服务可达，但检测 endpoint 不存在，HTTP 404"
            )
        case 400..<500:
            return APIReachabilityResult(
                state: .endpointIssue,
                statusCode: http.statusCode,
                latencyMS: latency,
                message: "服务可达，但请求被拒绝，HTTP \(http.statusCode)\(bodyHint.map { ": \($0)" } ?? "")"
            )
        default:
            return APIReachabilityResult(
                state: .endpointIssue,
                statusCode: http.statusCode,
                latencyMS: latency,
                message: "服务有响应，但返回 HTTP \(http.statusCode)"
            )
        }
    } catch {
        let latency = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        return APIReachabilityResult(
            state: .networkIssue,
            statusCode: nil,
            latencyMS: latency,
            message: "不可达：\(error.localizedDescription)"
        )
    }
}

func fetchProviderModels(provider: Provider, apiKey: String) async throws -> [String] {
    if provider.apiType == .xiaomiMimo {
        return provider.models
    }

    var request = try reachabilityRequest(provider: provider, apiKey: apiKey)
    request.timeoutInterval = 12

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 16
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
        throw APIError.httpError(http.statusCode, body)
    }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let models: [String]
    switch provider.apiType {
    case .openAI, .openAICompatible, .anthropic:
        let data = json?["data"] as? [[String: Any]] ?? []
        models = data.compactMap { $0["id"] as? String }
    case .gemini:
        let data = json?["models"] as? [[String: Any]] ?? []
        models = data.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
    case .xiaomiMimo:
        models = provider.models
    }

    let cleaned = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    guard !cleaned.isEmpty else { throw APIError.invalidResponse }
    return cleaned
}

private func reachabilityRequest(provider: Provider, apiKey: String) throws -> URLRequest {
    switch provider.apiType {
    case .openAI, .openAICompatible:
        var request = URLRequest(url: try endpointURL(baseURL: provider.baseURL, path: "/v1/models"))
        request.httpMethod = "GET"
        setOpenAICompatibleAuth(apiKey: apiKey, baseURL: provider.baseURL, request: &request)
        return request
    case .anthropic:
        var request = URLRequest(url: try endpointURL(baseURL: provider.baseURL, path: "/v1/models"))
        request.httpMethod = "GET"
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    case .gemini:
        let url = try endpointURL(baseURL: provider.baseURL, path: "/v1beta/models")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !apiKey.isEmpty {
            components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }
        guard let finalURL = components?.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        return request
    case .xiaomiMimo:
        var request = URLRequest(url: try endpointURL(baseURL: provider.baseURL, path: "/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setOpenAICompatibleAuth(apiKey: apiKey, baseURL: provider.baseURL, request: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.defaultModel,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
            "max_completion_tokens": 1,
            "stream": false,
            "thinking": ["type": "disabled"]
        ] as [String: Any])
        return request
    }
}

private func endpointURL(baseURL: String, path: String) throws -> URL {
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

private func isXiaomiMimoBaseURL(_ baseURL: String) -> Bool {
    baseURL.lowercased().contains("xiaomimimo.com")
}

private func setOpenAICompatibleAuth(apiKey: String, baseURL: String, request: inout URLRequest) {
    let key = normalizedOpenAICompatibleAPIKey(apiKey)
    guard !key.isEmpty else { return }
    if isXiaomiMimoBaseURL(baseURL) {
        request.setValue(key, forHTTPHeaderField: "api-key")
    } else {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

private func setOpenAICompatibleBearerAuth(apiKey: String, request: inout URLRequest) {
    let key = normalizedOpenAICompatibleAPIKey(apiKey)
    guard !key.isEmpty else { return }
    request.setValue(nil, forHTTPHeaderField: "api-key")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
}

// MARK: - Helpers

private func normalizedOpenAICompatibleAPIKey(_ apiKey: String) -> String {
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

private func checkHTTP(_ resp: URLResponse, bytes: URLSession.AsyncBytes) async throws {
    guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4096 { break }
            }
        } catch {
            throw APIError.httpError(http.statusCode, error.localizedDescription)
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw APIError.httpError(http.statusCode, body)
    }
}

private func checkHTTP(_ resp: URLResponse, data: Data) throws {
    guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data.prefix(4096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw APIError.httpError(http.statusCode, body)
    }
}

func makeService(apiType: Provider.APIType) -> ChatServiceProtocol {
    switch apiType {
    case .openAI, .openAICompatible, .xiaomiMimo:
        return OpenAIService()
    case .anthropic:                  return AnthropicService()
    case .gemini:                     return GeminiService()
    }
}
