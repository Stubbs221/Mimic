//
//  StatusIconTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class StatusIconClock { var now = 0.0 }

@Suite(.serialized) @MainActor
struct StatusIconTests {
    @Test func doubleChewHasTwoPeaksAndAClosedRest() {
        #expect(StatusIconAnimator.cycleDuration == 4)
        #expect(StatusIconAnimator.amount(at: 0) == 0)
        #expect(StatusIconAnimator.amount(at: 0.14) == 1)
        #expect(StatusIconAnimator.amount(at: 0.29) == 0)
        #expect(StatusIconAnimator.amount(at: 0.46) == 1)
        for time in stride(from: 0.64, through: 4, by: 0.08) { #expect(abs(StatusIconAnimator.amount(at: time)) < 0.0001) }
        #expect(StatusIconAnimator.amount(at: 1.74) == 0)
        #expect(abs(StatusIconAnimator.amount(at: 4.14) - 1) < 0.0001)
        for time in stride(from: 0.0, through: 4, by: 0.01) {
            let value = StatusIconAnimator.amount(at: time)
            #expect((0...1).contains(value))
            #expect(abs(value - StatusIconAnimator.amount(at: time + 16)) < 0.0001)
        }
    }

    @Test func refreshesKeepPhaseAndCompletionRestoresTheOriginalIcon() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button), settings = MimicMotionSettings(), clock = StatusIconClock()
        settings.reduceMotionOverride = false
        let animator = StatusIconAnimator(settings: settings, automaticallyTicks: false, clock: { clock.now })
        defer { animator.stop() }
        animator.update(button: button, working: true, marker: .none)
        clock.now = 0.14; animator.advance(to: clock.now)
        #expect(animator.isAnimating && animator.openness == 1)
        let open = animator.image
        animator.update(button: button, working: true, marker: .none)
        #expect(animator.openness == 1 && animator.image === open)
        // A marker refresh must not restart the chewing cycle or drop a prior failure.
        animator.update(button: button, working: true, marker: .failed)
        #expect(animator.openness == 1 && animator.image !== open)
        animator.update(button: button, working: false, marker: .failed)
        #expect(!animator.isAnimating && animator.openness == 0)
        #expect(try self.pixels(animator.image) == self.pixels(StatusIcon.image(marker: .failed)))
        clock.now = 9; animator.advance(to: clock.now)
        #expect(animator.openness == 0)
        animator.update(button: button, working: true, marker: .none)
        #expect(animator.openness == 0) // A new job starts a new cycle.
    }

    @Test func reducedMotionPauseAndScreenSleepHaveNoMovingFrames() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button), settings = MimicMotionSettings(), clock = StatusIconClock()
        settings.reduceMotionOverride = true
        let animator = StatusIconAnimator(settings: settings, automaticallyTicks: false, clock: { clock.now })
        defer { animator.stop() }
        animator.update(button: button, working: true, marker: .none)
        #expect(!animator.isAnimating && animator.openness == 1)
        clock.now = 0.29; animator.advance(to: clock.now)
        #expect(animator.openness == 1)
        settings.reduceMotionOverride = false; animator.refreshMotion()
        #expect(animator.isAnimating && animator.openness == 0)
        clock.now = 0.46; animator.advance(to: clock.now)
        #expect(animator.openness == 1)
        animator.setSuspended(true)
        #expect(!animator.isAnimating && animator.openness == 0)
        animator.setSuspended(false)
        #expect(animator.isAnimating && animator.openness == 1)
        animator.update(button: button, working: true, marker: .paused)
        #expect(!animator.isAnimating && animator.openness == 0)
        #expect(try self.pixels(animator.image) == self.pixels(StatusIcon.image(marker: .paused)))
    }

    @Test func liveDriverDoesNotRetainItsOwnerOrOverwriteStatusText() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button), settings = MimicMotionSettings()
        settings.reduceMotionOverride = false
        button.title = " 75%"; button.toolTip = "fixture"; button.setAccessibilityValue("fixture-health")
        var animator: StatusIconAnimator? = StatusIconAnimator(settings: settings)
        weak var owner = animator
        animator?.update(button: button, working: true, marker: .none)
        try await Task.sleep(for: .milliseconds(160))
        #expect(animator?.openness ?? 0 > 0)
        #expect(button.title == " 75%" && button.toolTip == "fixture")
        #expect((button.accessibilityValue() as? String) == "fixture-health")
        animator?.stop()
        let stopped = button.image
        try await Task.sleep(for: .milliseconds(80))
        #expect(button.image === stopped)
        animator?.update(button: button, working: true, marker: .none)
        animator = nil
        #expect(owner == nil)
    }

    @Test func templatesRemainTransparentAndUnclippedAtEveryOpening() throws {
        for marker in StatusIcon.Marker.allCases {
            let resting = try self.pixels(StatusIcon.image(marker: marker))
            for amount in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                let image = StatusIcon.image(marker: marker, openness: amount)
                #expect(image.isTemplate && image.size == NSSize(width: 20, height: 20))
                let bitmap = try self.bitmap(image), pixels = try self.pixels(image)
                if let directory = ProcessInfo.processInfo.environment["MIMIC_STATUS_ICON_PREVIEW_DIR"], marker == .none {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("chest-\(Int(amount * 100)).png"))
                }
                #expect(pixels.contains { $0 != 0 })
                if amount == 0 { #expect(pixels == resting) } else { #expect(pixels != resting) }
                // The moving lid stays inside 20 pt; clear interior pixels adapt to either menu-bar theme.
                for offset in 0..<80 {
                    #expect(bitmap.colorAt(x: offset, y: 0)?.alphaComponent == 0)
                    #expect(bitmap.colorAt(x: offset, y: 79)?.alphaComponent == 0)
                    #expect(bitmap.colorAt(x: 0, y: offset)?.alphaComponent == 0)
                    #expect(bitmap.colorAt(x: 79, y: offset)?.alphaComponent == 0)
                }
                #expect(bitmap.colorAt(x: 40, y: 24)?.alphaComponent == 0)
            }
        }
    }

    @Test func onlyExecutingWorkChewsAndInputWaitsKeepThePauseMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusIcon-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.aiUsage.stop(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .format, project: ProjectContext(path: root.path))
        record.status = .queued; model.records = [record]
        #expect(!StatusIconActivity(model: model).working)
        record.status = .running; model.records = [record]
        #expect(StatusIconActivity(model: model).working)
        model.awaitingInput.insert(record.id)
        #expect(!StatusIconActivity(model: model).working && StatusIconActivity(model: model).marker == .paused)
        #expect(StatusIconActivity(model: model).healthKey == "panel.notice.input")
        model.awaitingInput.remove(record.id); model.unreadFailure = true
        #expect(StatusIconActivity(model: model).working && StatusIconActivity(model: model).marker == .failed)
        record.status = .succeeded; model.records = [record]
        #expect(!StatusIconActivity(model: model).working && StatusIconActivity(model: model).marker == .failed)
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 80, height: 80))
        image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 80))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let bitmap = try self.bitmap(image)
        return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
