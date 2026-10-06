//
//  InterfaceMapTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
@testable import Mimic

@Suite(.serialized)
@MainActor
struct InterfaceMapTests {
    @Test
    func catalogueHasLocalizedNamesAndSearchesDescriptions() {
        #expect(Set(InterfaceTerm.allCases.map(\.id)).count == InterfaceTerm.allCases.count)
        for term in InterfaceTerm.allCases {
            #expect(!term.title.hasPrefix("interface.term."))
            #expect(!term.detail.hasPrefix("interface.term."))
        }
        #expect(InterfaceTerm.matching("   ") == InterfaceTerm.allCases)
        #expect(InterfaceTerm.matching("ТЕРМИНАЛ").contains(.terminal))
        #expect(InterfaceTerm.matching("правому клику").contains(.quickMenu))
        #expect(InterfaceTerm.matching("несуществующий элемент").isEmpty)
    }

    @Test
    func referenceWindowFitsMinimumWidthInBothAppearances() async throws {
        let output = URL(fileURLWithPath: "/private/tmp/MimicInterfaceMapRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = NSHostingView(rootView: InterfaceMapView().environment(\.colorScheme, dark ? .dark : .light).frame(width: 440, height: 620))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 620)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            #expect(view.fittingSize.width <= 441)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
            window.close()
        }
    }
}
