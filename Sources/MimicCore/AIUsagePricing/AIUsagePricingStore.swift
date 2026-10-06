//
//  AIUsagePricingStore.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

/// Only public model catalogs are cached. Usage, account identities and log entries remain memory-only.
/// Serves bundled/cached data immediately; refresh failures never prevent the local trend from loading.
actor AIUsagePricingStore {
    enum Source: String, CaseIterable, Codable, Sendable { case litellm, modelsDev, supplement }
    struct FetchState: Codable {
        var etag: String?
        var fetchedAt: Date?
        var failedAt: Date?
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let sources: [Source: URL] = [
        .litellm: URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        .modelsDev: URL(string: "https://models.dev/api.json")!,
        .supplement: URL(string: "https://robinebers.github.io/openusage/pricing_supplement.json")!
    ]
    private let directory: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private var states: [Source: FetchState] = [:]
    private var currentPricing: ModelPricing?
    private var refreshing: Task<Void, Never>?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mimic/AIUsagePricing"), clock: @escaping @Sendable () -> Date = Date.init, transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIUsageError.invalidResponse }
        return (data, response)
    }) {
        self.directory = directory; self.clock = clock; self.transport = transport
    }

    func current(refresh: Bool = true) -> ModelPricing {
        if self.currentPricing == nil {
            self.states = (try? Data(contentsOf: self.directory.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode([Source: FetchState].self, from: $0) } ?? [:]
            self.currentPricing = self.load()
        }
        if refresh, self.refreshing == nil, Source.allCases.contains(where: self.isDue) {
            self.refreshing = Task { await self.refreshDueSources() }
        }
        return self.currentPricing ?? .empty
    }

    // MARK: - Offline catalogs

    private func resource(_ name: String) -> Data? {
        MimicCoreResources.bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }
    private func cached(_ source: Source) -> Data? {
        try? Data(contentsOf: self.directory.appendingPathComponent(source.rawValue + ".json"))
    }
    private func catalog(_ source: Source, resource name: String) -> PricingCatalog {
        let bundled = self.resource(name).flatMap { try? PricingCatalogCodecs.catalogFromCompact($0) } ?? PricingCatalog()
        guard let cached = self.cached(source).flatMap({ try? PricingCatalogCodecs.catalogFromCompact($0) }) else { return bundled }
        return bundled.merging(cached)
    }
    private func load() -> ModelPricing {
        let bundled = self.resource("pricing_supplement").flatMap { try? PricingSupplement.decode(from: $0) } ?? PricingSupplement()
        let cached = self.cached(.supplement).flatMap { try? PricingSupplement.decode(from: $0) }
        let supplement: PricingSupplement
        if let cached {
            supplement = (bundled.updatedAt ?? "") > (cached.updatedAt ?? "") ? bundled : cached.fillingMissingFallbackModels(from: bundled)
        } else { supplement = bundled }
        return ModelPricing(supplement: supplement, primary: self.catalog(.litellm, resource: "pricing_litellm_snapshot"), secondary: self.catalog(.modelsDev, resource: "pricing_models_dev_snapshot"))
    }

    // MARK: - Public feed refresh

    private func isDue(_ source: Source) -> Bool {
        let now = self.clock(), state = self.states[source]
        if let failed = state?.failedAt, now.timeIntervalSince(failed) < 1800 { return false }
        return state?.fetchedAt.map { now.timeIntervalSince($0) >= 3600 } ?? true
    }
    /// Internal hook also allows offline transport fixtures to await a complete refresh deterministically.
    func refreshDueSources() async {
        defer { self.refreshing = nil }
        for source in Source.allCases where self.isDue(source) {
            guard !Task.isCancelled, let url = Self.sources[source] else { return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue(self.states[source]?.etag, forHTTPHeaderField: "If-None-Match")
            do {
                let (data, response) = try await self.transport(request)
                guard !Task.isCancelled, data.count <= 20 * 1024 * 1024 else { throw AIUsageError.invalidResponse }
                switch response.statusCode {
                case 304:
                    guard self.cached(source) != nil else { throw AIUsageError.invalidResponse }
                case 200:
                    let cache: Data
                    switch source {
                    case .litellm: cache = try PricingCatalogCodecs.compactData(from: PricingCatalogCodecs.catalogFromLiteLLM(data))
                    case .modelsDev: cache = try PricingCatalogCodecs.compactData(from: PricingCatalogCodecs.catalogFromModelsDev(data))
                    case .supplement:
                        _ = try PricingSupplement.decode(from: data); cache = data
                    }
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    try cache.write(to: self.directory.appendingPathComponent(source.rawValue + ".json"), options: .atomic)
                default: throw AIUsageError.network
                }
                self.states[source] = FetchState(etag: response.value(forHTTPHeaderField: "ETag") ?? self.states[source]?.etag, fetchedAt: self.clock(), failedAt: nil)
                self.currentPricing = self.load()
            } catch {
                guard !Task.isCancelled else { return }
                var state = self.states[source] ?? FetchState(); state.failedAt = self.clock(); self.states[source] = state
            }
        }
        if let data = try? JSONEncoder().encode(self.states) {
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try? data.write(to: self.directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}
