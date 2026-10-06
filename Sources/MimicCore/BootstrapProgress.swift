//
//  BootstrapProgress.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

/// Tracks captured substeps using existing script messages; only a successful exit resolves the process step.
public struct BootstrapProgress: Sendable {
    public enum Step: String, CaseIterable, Codable, Sendable { case brew, mint, bundler, xcresults, allurectl, uiConfiguration, certificates, registry, registries, process }
    public let steps: [Step]
    public private(set) var currentStep: Step?
    public private(set) var completedSteps: Set<Step> = []
    public private(set) var skippedSteps: Set<Step> = []
    private var finished = false
    public var fraction: Double { Double(self.completedSteps.union(self.skippedSteps).count) / Double(self.steps.count) }
    public enum Stage: String, Codable, Sendable { case dependencies, uiTests, setup }
    public private(set) var stage: Stage?
    public let stages: [Stage]
    public private(set) var completed: Set<Stage> = []
    private var tail = Data()
    private let matchers: [ProgressMatcher]
    private var observed = Set<Int>()
    public init(options: BootstrapOptions = BootstrapOptions(), matchers: [ProgressMatcher] = []) {
        self.matchers = matchers
        self.steps = (options.full || options.dependencies ? [.brew, .mint, .bundler] : [])
            + (options.full || options.uiDependencies ? [.xcresults, .allurectl, .uiConfiguration] : [])
            + (options.full || options.setup ? (options.device && options.match ? [.certificates] : []) + [.registry, .registries] : []) + [.process]
        self.stages = [options.full || options.dependencies ? .dependencies : nil,
                       options.full || options.uiDependencies ? .uiTests : nil,
                       options.full || options.setup ? .setup : nil].compactMap(\.self)
    }

    /// Success completes the final phase; failure or cancellation never fills the bar.
    public mutating func finish(succeeded: Bool) { self.finished = true; if succeeded { self.completed = Set(self.stages); self.completedSteps = Set(self.steps); self.currentStep = .process } }

    /// Match split UTF-8/PTY fragments in stream order. Only observed events advance progress.
    public mutating func consume(_ bytes: Data) {
        guard !finished else { return }
        tail.append(bytes)
        if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
        let output = String(decoding: tail, as: UTF8.self).replacingOccurrences(of: "\\u001B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let events = matchers.enumerated().compactMap { index, matcher -> (Int, ProgressMatcher, String.Index)? in
            guard !observed.contains(index), let range = output.range(of: matcher.contains) else { return nil }
            return (index, matcher, range.lowerBound)
        }.sorted { $0.2 < $1.2 }
        for (index, matcher, _) in events {
            observed.insert(index)
            if let step = matcher.step, steps.contains(step) {
                switch matcher.event {
                case .start: currentStep = step
                case .complete: completedSteps.insert(step); currentStep = step
                case .skip: skippedSteps.insert(step); completedSteps.remove(step); currentStep = step
                case nil: break
                }
            }
            if let next = matcher.stage, stages.contains(next) {
                if matcher.event == .start { stage = next }
                else if matcher.event == .complete || matcher.event == .skip { completed.insert(next) }
            }
        }
        if steps.dropLast().allSatisfy({ completedSteps.contains($0) || skippedSteps.contains($0) }) { currentStep = .process }
    }
}
