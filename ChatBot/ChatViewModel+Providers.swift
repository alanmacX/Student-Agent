import Foundation
import SwiftUI

extension ChatViewModel {
    // MARK: - Providers management
    
    func provider(for id: String) -> Provider {
        allProviders.first { $0.id == id } ?? .openAI
    }

    func apiKey(for provider: Provider) -> String {
        if provider.isBuiltin {
            switch provider.apiType {
            case .openAI:      return openAIKey
            case .anthropic:   return anthropicKey
            case .gemini:      return geminiKey
            case .xiaomiMimo:  return mimoKey
            default:           return ""
            }
        }
        return provider.customAPIKey
    }

    func availableModels(for provider: Provider) -> [String] {
        if provider.apiType == .xiaomiMimo {
            return provider.models.filter { !$0.isEmpty }
        }
        let models = providerModelOverrides[provider.id] ?? provider.models
        return models.filter { !$0.isEmpty }
    }

    func isProviderUsable(_ provider: Provider) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    func economicalModel(for provider: Provider) -> String {
        let known = availableModels(for: provider).compactMap { model -> (String, Double)? in
            guard let pricing = knownPricing[model] else { return nil }
            return (model, pricing.inputPerM + pricing.outputPerM)
        }
        if let cheapest = known.min(by: { $0.1 < $1.1 })?.0 {
            return cheapest
        }
        return availableModels(for: provider).first ?? provider.defaultModel
    }

    func refreshModels(for providerID: String) async throws -> [String] {
        let provider = provider(for: providerID)
        let models = try await fetchProviderModels(provider: provider, apiKey: apiKey(for: provider))
        providerModelOverrides[providerID] = models
        if let index = customProviders.firstIndex(where: { $0.id == providerID }) {
            customProviders[index].models = models
        }
        for index in conversations.indices where conversations[index].providerID == providerID {
            if !models.contains(conversations[index].model), let first = models.first {
                conversations[index].model = first
            }
        }
        saveSettings()
        saveConversations()
        return models
    }

    func addCustomProvider(name: String, baseURL: String, apiKey: String, models: String) {
        let list = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        customProviders.append(Provider(
            id: UUID().uuidString, name: name, apiType: .openAICompatible,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            models: list.isEmpty ? ["default"] : list,
            iconName: "network", colorHex: "6B7280",
            customAPIKey: apiKey
        ))
        saveSettings()
    }

    func updateCustomProvider(_ p: Provider) {
        if let i = customProviders.firstIndex(where: { $0.id == p.id }) {
            customProviders[i] = p; saveSettings()
        }
    }

    func deleteCustomProvider(_ p: Provider) {
        customProviders.removeAll { $0.id == p.id }
        if scheduleAgentProviderID == p.id {
            scheduleAgentProviderID = nil
        }
        for i in conversations.indices where conversations[i].providerID == p.id {
            conversations[i].providerID = "openai"
            conversations[i].model = Provider.openAI.defaultModel
        }
        saveSettings(); saveConversations()
    }

    func updateScheduleAgentProviderSelection(_ selectionID: String) {
        let nextID = selectionID == ChatViewModel.automaticScheduleAgentProviderID ? nil : selectionID
        guard scheduleAgentProviderID != nextID else { return }
        scheduleAgentProviderID = nextID
        saveSettings()
    }
}
