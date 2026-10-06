//
//  AISettingsModel.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import Combine
import Foundation
import MimicCore

/// Persists executable/model preferences only. Each check is an isolated, non-inference pipe process.
@MainActor
final class AISettingsModel: ObservableObject {
    @Published
    var settings: AISettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { self.defaults.set(data, forKey: "ai.settings") }
            self.capabilities.removeAll(); self.errors.removeAll()
        }
    }

    @Published
    private(set) var checking: AIProvider?
    @Published
    private(set) var capabilities: [AIProvider: AICapability] = [:]
    @Published
    private(set) var errors: [AIProvider: AIError] = [:]
    private let defaults: UserDefaults
    private let helper: URL
    private var runner: AIProcessRunner?
    private var stopping = false
    var onIdle: (() -> Void)?
    var mayAdmit: () -> Bool = { true }

    init(defaults: UserDefaults, helper: URL) {
        self.defaults = defaults; self.helper = helper
        if let data = defaults.data(forKey: "ai.settings"), let settings = try? JSONDecoder().decode(AISettings.self, from: data) { self.settings = settings }
        else {
            let codex = AIProviderAdapters.resolve(provider: .codex, configuredPath: "")
            let claude = AIProviderAdapters.resolve(provider: .claude, configuredPath: "")
            self.settings = AISettings(provider: codex == nil && claude != nil ? .claude : .codex)
        }
    }

    func check(_ provider: AIProvider) {
        guard self.mayAdmit(), self.checking == nil, !self.stopping else { return }
        let settings = self.settings
        self.checking = provider; self.errors[provider] = nil; self.capabilities[provider] = nil
        let runner = AIProcessRunner(helper: self.helper, timeLimit: 8)
        self.runner = runner
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { self.capabilities[provider] = try await AICLIInspector.check(provider: provider, settings: settings, runner: runner, isCancelled: { self.stopping }) }
            catch { if !self.stopping { self.errors[provider] = (error as? AIError) ?? .processFailed } }
            self.runner = nil; self.checking = nil; self.onIdle?()
        }
    }

    func stop() { self.stopping = true; self.runner?.cancel() }
}
