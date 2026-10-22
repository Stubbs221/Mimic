//
//  TaskHistoryPersistence.swift
//  Mimic
//
//  Created by Василий Маслов on 21.10.2026.
import Foundation
import MimicCore

/// Orders immutable snapshots and exposes durability barriers without blocking the UI thread.
@MainActor final class TaskHistoryPersistence {
    private let worker: HistoryPersistence
    private var tail: Task<Void, Error>?
    private var deferred: Task<Void, Never>?
    private var buffered: [TaskRecord]?
    private var bufferedSince: ContinuousClock.Instant?
    var hasUnflushedChanges: Bool { buffered != nil || savedRevision < revision }
    private(set) var revision = 0
    private(set) var savedRevision = 0
    var onError: ((Error) -> Void)?

    init(store: HistoryStore) { worker = HistoryPersistence(store: store) }

    func save(_ records: [TaskRecord], coalescing: Bool = false) {
        deferred?.cancel(); deferred = nil
        if coalescing, bufferedSince.map({ $0.duration(to: .now) < .seconds(1) }) ?? true {
            if bufferedSince == nil { bufferedSince = .now }
            buffered = records
            deferred = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let buffered = self.buffered else { return }
                self.save(buffered)
            }
            return
        }
        buffered = nil; bufferedSince = nil
        revision += 1
        let generation = revision, previous = tail, worker = worker
        let task = Task.detached(priority: .utility) {
            if let previous { _ = await previous.result }
            try await worker.save(records)
        }
        tail = task
        Task { [weak self] in
            do { try await task.value; if let self { self.savedRevision = max(self.savedRevision, generation) } }
            catch { self?.onError?(error) }
        }
    }

    /// Critical admission/launch/exit paths await all snapshots submitted before this barrier.
    func flush() async throws {
        if let buffered { save(buffered) }
        let generation = revision
        try await tail?.value
        savedRevision = max(savedRevision, generation)
    }
}
