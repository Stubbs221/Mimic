//
//  MimicWindowMotion.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import Observation
import SwiftUI

/// Hosting identity is stable. This presentation object contains no execution or CI state.
@MainActor @Observable
final class MimicWindowPresentation {
    var offset: CGFloat = 0
    var interactive = false
}

struct MimicWindowRoot<Content: View>: View {
    let presentation: MimicWindowPresentation
    let settings: MimicMotionSettings
    let content: Content
    init(presentation: MimicWindowPresentation, settings: MimicMotionSettings, @ViewBuilder content: () -> Content) {
        self.presentation = presentation; self.settings = settings; self.content = content()
    }
    var body: some View {
        self.content.environment(\.mimicMotionSettings, self.settings)
            .offset(y: self.presentation.offset).allowsHitTesting(self.presentation.interactive)
            .accessibilityHidden(!self.presentation.interactive).preferredColorScheme(self.settings.previewColorScheme)
    }
}

/// Desired visibility changes immediately; visual tracks can be retargeted from the current frame.
/// One driver services both tracks and never waits before executing a task or stopping CI polling.
@MainActor
final class MimicWindowMotion {
    let window: NSWindow
    let settings: MimicMotionSettings
    let presentation = MimicWindowPresentation()
    private(set) var desiredVisible = false
    private(set) var revision: UInt64 = 0
    var visibilityChanged: (Bool) -> Void = { _ in }
    private struct VisibilityTrack {
        let revision: UInt64
        let start: Double
        let duration: Double
        let alpha: CGFloat
        let offset: CGFloat
        let targetAlpha: CGFloat
        let targetOffset: CGFloat
    }
    private struct FrameTrack {
        let start: Double
        let duration: Double
        let origin: NSRect
        let target: NSRect
    }
    private var visibility: VisibilityTrack?
    private var geometry: FrameTrack?
    private var driver: Timer?
    private let clock: () -> Double
    private let automaticallyTicks: Bool
    var isAnimatingFrame: Bool { self.geometry != nil }
    var isTransitioning: Bool { self.visibility != nil }

    init(window: NSWindow, settings: MimicMotionSettings, automaticallyTicks: Bool = true, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.window = window; self.settings = settings; self.automaticallyTicks = automaticallyTicks; self.clock = clock
        self.window.alphaValue = 0
    }

    func setVisible(_ visible: Bool, source: MimicMotionSource = .automatic, key: Bool = false) {
        if self.desiredVisible == visible {
            // Escape/keyboard navigation also finishes an already pending pointer transition.
            if source == .keyboard { self.finishVisibility(); if visible && key { self.window.makeKey() } }
            return
        }
        self.advance(to: self.clock())
        self.revision &+= 1; self.desiredVisible = visible
        self.presentation.interactive = visible; self.window.ignoresMouseEvents = !visible
        if !visible { self.window.makeFirstResponder(nil); self.window.resignKey() }
        self.visibilityChanged(visible)
        let policy = MimicMotionPolicy(source: source, reduceMotion: self.settings.nativeReduceMotion, multiplier: self.settings.multiplier)
        if visible && !self.window.isVisible {
            self.window.alphaValue = 0; self.presentation.offset = policy.moves ? -8 : 0
            if key { self.window.makeKeyAndOrderFront(nil) } else { self.window.orderFrontRegardless() }
        } else if visible && key { self.window.makeKey() }
        let duration = policy.duration(visible ? .enter : .exit)
        if !policy.moves { self.presentation.offset = 0 }
        self.visibility = VisibilityTrack(revision: self.revision, start: self.clock(), duration: duration, alpha: self.window.alphaValue,
                                          offset: self.presentation.offset, targetAlpha: visible ? 1 : 0, targetOffset: visible || !policy.moves ? 0 : -8)
        if duration == 0 { self.finishVisibility() } else { self.startDriver() }
    }

    func setFrame(_ frame: NSRect, source: MimicMotionSource = .automatic, immediate: Bool = false) {
        self.advance(to: self.clock())
        let policy = MimicMotionPolicy(source: source, reduceMotion: self.settings.nativeReduceMotion, multiplier: self.settings.multiplier)
        let duration = immediate || !self.window.isVisible ? 0 : policy.duration(.geometry)
        func matches(_ other: NSRect) -> Bool {
            abs(frame.minX - other.minX) < 0.5 && abs(frame.minY - other.minY) < 0.5 && abs(frame.width - other.width) < 0.5 && abs(frame.height - other.height) < 0.5
        }
        if duration > 0, let target = self.geometry?.target, matches(target) { return }
        if self.geometry == nil, matches(self.window.frame) { return }
        if duration == 0 { self.geometry = nil; self.window.setFrame(frame, display: true); return }
        self.geometry = FrameTrack(start: self.clock(), duration: duration, origin: self.window.frame, target: frame)
        self.startDriver()
    }

    /// Dragging takes ownership of the current native frame, without snapping to the old target.
    func beginDrag() { self.advance(to: self.clock()); self.geometry = nil }

    /// Exposed internally for deterministic fixture checks of first, middle and final frames.
    func advance(to now: Double) {
        if self.settings.nativeReduceMotion {
            if let track = self.visibility, track.offset != 0 || track.targetOffset != 0 {
                self.presentation.offset = 0
                self.visibility = VisibilityTrack(revision: track.revision, start: now, duration: min(max(0, track.duration - (now - track.start)), 0.125 * self.settings.multiplier),
                                                  alpha: self.window.alphaValue, offset: 0, targetAlpha: track.targetAlpha, targetOffset: 0)
            }
            if let track = self.geometry { self.window.setFrame(track.target, display: true); self.geometry = nil }
        }
        if let track = self.visibility {
            let raw = track.duration == 0 ? 1 : (now - track.start) / track.duration
            let fraction = CGFloat(MimicMotionPolicy.fraction(raw))
            self.window.alphaValue = track.alpha + (track.targetAlpha - track.alpha) * fraction
            self.presentation.offset = track.offset + (track.targetOffset - track.offset) * fraction
            if raw >= 1 { self.completeVisibility(revision: track.revision) }
        }
        if let track = self.geometry {
            let raw = (now - track.start) / track.duration
            let fraction = CGFloat(MimicMotionPolicy.fraction(raw, geometry: true))
            func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * fraction }
            let frame = NSRect(x: interpolate(track.origin.minX, track.target.minX), y: interpolate(track.origin.minY, track.target.minY),
                               width: interpolate(track.origin.width, track.target.width), height: interpolate(track.origin.height, track.target.height))
            self.window.setFrame(frame, display: true)
            if raw >= 1 { self.geometry = nil }
        }
    }

    /// A revision check prevents an old exit from ordering out a newly reopened window.
    func completeVisibility(revision: UInt64) {
        guard let track = self.visibility, track.revision == revision, self.revision == revision else { return }
        self.window.alphaValue = track.targetAlpha; self.presentation.offset = track.targetOffset; self.visibility = nil
        if !self.desiredVisible { self.window.orderOut(nil) }
    }

    private func finishVisibility() {
        if let track = self.visibility { self.completeVisibility(revision: track.revision) }
    }
    private func startDriver() {
        guard self.automaticallyTicks, self.driver == nil else { return }
        // Common modes keep a pending window fade moving while a native menu tracks input.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.driver = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        self.advance(to: self.clock())
        if self.visibility == nil && self.geometry == nil { self.driver?.invalidate(); self.driver = nil }
    }
    func stop() { self.driver?.invalidate(); self.driver = nil; self.visibility = nil; self.geometry = nil }
}
