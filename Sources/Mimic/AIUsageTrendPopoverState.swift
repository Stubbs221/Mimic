//
//  AIUsageTrendPopoverState.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
// Hover timing and selection adapted from OpenUsage 0.7.13 (MIT), Robin Ebers.
import Combine
import Foundation
import MimicCore

/// Owns deliberate hover timing and day selection; opening detail never requests usage data.
@MainActor
final class AIUsageTrendPopoverState: ObservableObject {
    typealias Schedule = (_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
    @Published private(set) var isPresented = false
    @Published private(set) var overInline = false
    @Published private(set) var isPinned = false
    @Published private(set) var points: [AIUsageDailyPoint]
    @Published private(set) var activeIndex: Int?
    var presentationChanged: (() -> Void)?
    var contentChanged: (() -> Void)?
    private var acceptsEvents = true
    private var overDetail = false
    private var cancelShow: (() -> Void)?
    private var cancelHide: (() -> Void)?
    private let schedule: Schedule

    init(points: [AIUsageDailyPoint], schedule: Schedule? = nil) {
        self.points = points
        self.schedule = schedule ?? Self.scheduleTask
    }
    /// Equal peaks resolve to the latest calendar day.
    var peakIndex: Int? {
        self.points.indices.reduce(nil as Int?) { peak, index in
            guard let peak else { return index }
            return self.points[index].tokens >= self.points[peak].tokens ? index : peak
        }
    }
    var selectedIndex: Int? { self.activeIndex ?? self.peakIndex }
    var selectedPoint: AIUsageDailyPoint? { self.selectedIndex.map { self.points[$0] } }

    // MARK: - Hover and explicit disclosure

    func inlineHover(_ inside: Bool) {
        guard self.acceptsEvents else { return }
        guard self.overInline != inside else { return }
        self.overInline = inside
        if inside {
            self.cancelHide?(); self.cancelHide = nil
            guard !self.isPresented, !self.points.isEmpty else { return }
            self.cancelShow = self.schedule(0.4) { [weak self] in
                guard let self else { return }
                self.cancelShow = nil
                if self.overInline, !self.points.isEmpty { self.setPresented(true) }
            }
        } else { self.scheduleHide() }
    }
    func detailHover(_ inside: Bool) {
        guard self.acceptsEvents else { return }
        self.overDetail = inside
        if inside { self.cancelHide?(); self.cancelHide = nil }
        else { self.clearSelection(); self.scheduleHide() }
    }
    /// Click, Return, Space and the accessibility action pin until explicit dismissal.
    func toggleExplicit() {
        guard self.acceptsEvents else { return }
        if self.isPresented, self.isPinned { self.dismiss(); return }
        guard !self.points.isEmpty else { return }
        self.cancelTimers(); self.isPinned = true
        if self.isPresented { self.presentationChanged?() } else { self.setPresented(true) }
    }
    func dismiss() {
        self.cancelTimers(); self.overDetail = false
        if self.overInline { self.overInline = false }
        if self.isPinned { self.isPinned = false }
        self.resetSelection(); self.setPresented(false)
    }
    /// Native-view teardown cancels work immediately, then resets observation after SwiftUI invalidation.
    func detach() {
        self.acceptsEvents = false
        self.cancelTimers(); self.presentationChanged = nil; self.contentChanged = nil
        Task { @MainActor [weak self] in
            self?.dismiss(); self?.acceptsEvents = true
        }
    }
    private func scheduleHide() {
        self.cancelShow?(); self.cancelShow = nil
        self.cancelHide?(); self.cancelHide = nil
        guard !self.isPinned else { return }
        self.cancelHide = self.schedule(0.18) { [weak self] in
            guard let self else { return }
            self.cancelHide = nil
            if !self.overInline, !self.overDetail, !self.isPinned { self.setPresented(false) }
        }
    }
    private func setPresented(_ presented: Bool) {
        guard self.isPresented != presented else { return }
        self.isPresented = presented; self.presentationChanged?()
    }
    private func cancelTimers() {
        self.cancelShow?(); self.cancelShow = nil; self.cancelHide?(); self.cancelHide = nil
    }
    private static func scheduleTask(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    // MARK: - One shared set of calendar points

    func replacePoints(_ points: [AIUsageDailyPoint]) {
        guard self.points != points else { return }
        self.points = points; self.clearSelection()
        if points.isEmpty { self.dismiss() }
        else { self.contentChanged?() }
    }
    func select(_ index: Int) {
        guard self.acceptsEvents else { return }
        guard self.points.indices.contains(index), self.activeIndex != index else { return }
        self.activeIndex = index; self.contentChanged?()
    }
    func moveSelection(_ offset: Int) {
        guard let index = self.selectedIndex else { return }
        self.select(min(self.points.count - 1, max(0, index + offset)))
    }
    func clearSelection() {
        guard self.acceptsEvents else { return }
        self.resetSelection()
    }
    private func resetSelection() {
        guard self.activeIndex != nil else { return }
        self.activeIndex = nil; self.contentChanged?()
    }
}
