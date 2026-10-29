//
//  PanelTextInputTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor
struct PanelTextInputTests {
    private func panel() -> MimicPopover {
        _ = NSApplication.shared
        let panel = MimicPopover(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 180),
                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func click(in window: NSWindow, at point: NSPoint, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        try #require(event.window === window, "Mouse-event tests require access to the macOS window server.")
        return event
    }

    @Test(arguments: [false, true])
    func fieldEditorRemainsActiveAfterKeyLoss(secure: Bool) throws {
        let panel = self.panel()
        defer { panel.contentView = nil; panel.close() }
        let field = secure ? NSSecureTextField(string: "draft") : NSTextField(string: "draft")
        field.frame = NSRect(x: 10, y: 20, width: 280, height: 24)
        panel.contentView?.addSubview(field)
        panel.makeKeyAndOrderFront(nil)
        field.selectText(nil)
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(panel.hasActiveTextInput)

        panel.resignKey()
        #expect(panel.hasActiveTextInput)
        #expect(panel.firstResponder === editor)
        #expect(editor.string == "draft" && editor.selectedRange() == NSRange(location: 1, length: 2))

        panel.makeKeyAndOrderFront(nil)
        editor.insertText("copied", replacementRange: editor.selectedRange())
        #expect(editor.string == "dcopiedft")
        panel.makeFirstResponder(nil)
        #expect(!panel.hasActiveTextInput)
    }

    @Test(arguments: PanelAppearance.allCases)
    func swiftUIInputsKeepTheirNativeEditor(appearance: PanelAppearance) async throws {
        let panel = self.panel()
        defer { panel.contentView = nil; panel.close() }
        let host = NSHostingView(rootView: VStack {
            TextField("Value", text: .constant("draft")).mimicInput()
            SecureField("Token", text: .constant("draft")).mimicInput()
            TextEditor(text: .constant("draft")).mimicInput()
        }.padding(20).environment(\.mimicPanelAppearance, appearance).frame(width: 320, height: 180))
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func inputs(_ view: NSView) -> [NSView] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor { return [editor] }
            return view.subviews.flatMap(inputs)
        }
        let fields = inputs(host)
        #expect(fields.count == 3)
        for field in fields {
            panel.makeKeyAndOrderFront(nil)
            if let field = field as? NSTextField { field.selectText(nil) }
            else { #expect(panel.makeFirstResponder(field)) }
            let responder = try #require(panel.firstResponder as? NSTextView)
            #expect(panel.hasActiveTextInput)
            let visible = field.visibleRect.intersection(field.bounds)
            try #require(!visible.isEmpty)
            let point = field.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            panel.releaseTextInputFocus(for: try self.click(in: panel, at: point))
            panel.releaseTextInputFocus(for: try self.click(in: panel, at: point, type: .rightMouseDown))
            #expect(panel.hasActiveTextInput && panel.firstResponder === responder)
            panel.resignKey()
            #expect(panel.hasActiveTextInput && panel.firstResponder === responder)
            panel.releaseTextInputFocus(for: try self.click(in: panel, at: NSPoint(x: 2, y: 2)))
            #expect(!panel.hasActiveTextInput)
        }
        panel.makeFirstResponder(nil)
        #expect(!panel.hasActiveTextInput)
    }

    @Test func externalClickPreservesInputButInternalButtonReleasesIt() throws {
        let panel = self.panel(), other = self.panel()
        defer { panel.contentView = nil; panel.close(); other.close() }
        let field = NSTextField(string: "draft")
        field.frame = NSRect(x: 10, y: 100, width: 280, height: 24)
        let button = NSButton(title: "Done", target: nil, action: nil)
        button.frame = NSRect(x: 10, y: 20, width: 80, height: 24)
        panel.contentView?.addSubview(field); panel.contentView?.addSubview(button)
        panel.makeKeyAndOrderFront(nil); field.selectText(nil)
        panel.releaseTextInputFocus(for: try self.click(in: other, at: NSPoint(x: 20, y: 20)))
        #expect(panel.hasActiveTextInput)
        panel.releaseTextInputFocus(for: try self.click(in: panel, at: NSPoint(x: 20, y: 30)))
        #expect(!panel.hasActiveTextInput && field.stringValue == "draft")
    }

    @Test func consumedCardPressAlsoReleasesInput() throws {
        let panel = self.panel()
        let field = NSTextField(string: "draft")
        field.frame = NSRect(x: 10, y: 100, width: 280, height: 24)
        panel.contentView?.addSubview(field)
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .utils) },
                                     click: { _ in }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
        let tracker = PanelDragBridge.TrackingView(callbacks: bridge)
        tracker.frame = try #require(panel.contentView).bounds; panel.contentView?.addSubview(tracker)
        defer { tracker.stop(); panel.contentView = nil; panel.close() }
        panel.makeKeyAndOrderFront(nil); field.selectText(nil)
        #expect(panel.hasActiveTextInput)
        let event = try self.click(in: panel, at: NSPoint(x: 20, y: 20))
        #expect(tracker.receive(event) == nil)
        #expect(!panel.hasActiveTextInput && field.stringValue == "draft")
    }

    @Test func multilineInputAndReadOnlySelection() {
        let panel = self.panel()
        defer { panel.contentView = nil; panel.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        editor.string = "first line\nsecond line"
        panel.contentView?.addSubview(editor)
        #expect(panel.makeFirstResponder(editor))
        #expect(panel.hasActiveTextInput)
        editor.isEditable = false
        #expect(!panel.hasActiveTextInput)
        #expect(panel.makeFirstResponder(nil))
        #expect(!panel.hasActiveTextInput)
    }

    @Test func explicitEscapeStillDismissesAnActiveInput() {
        let panel = self.panel()
        defer { panel.contentView = nil; panel.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        panel.contentView?.addSubview(editor)
        #expect(panel.makeFirstResponder(editor))
        #expect(panel.hasActiveTextInput)
        var dismissed = false
        panel.dismiss = { dismissed = true }
        panel.cancelOperation(nil)
        #expect(dismissed)
    }
}
