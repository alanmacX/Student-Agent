import Foundation
import SwiftUI

extension ChatViewModel {
    // MARK: - API Helpers
    func checkBalance(for provider: Provider) async throws -> [ProviderBalance] {
        let key = apiKey(for: provider)
        guard !key.isEmpty else { throw APIError.httpError(401, "No API key configured") }
        return try await fetchBalance(baseURL: provider.baseURL, apiKey: key)
    }

    func checkAPIReachability(for provider: Provider) async -> APIReachabilityResult {
        await checkProviderReachability(provider: provider, apiKey: apiKey(for: provider))
    }
}
