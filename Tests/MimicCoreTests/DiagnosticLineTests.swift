//
//  DiagnosticLineTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 03.10.2026.
import Testing
@testable import MimicCore

struct DiagnosticLineTests {
    @Test
    func foldingPreservesOrderNumbersAndOriginalText() {
        let original = "error\nerror\nerror\ncontext\ncontext\nerror\n\n"
        let groups = DiagnosticLineGroup.groups(in: original)
        #expect(groups.map(\.count) == [3, 2, 1, 2])
        #expect(groups.map(\.firstLine) == [1, 4, 6, 7])
        #expect(groups.map(\.canFold) == [true, false, false, false])
        let reconstructed = groups.flatMap { Array(repeating: $0.text, count: $0.count) }.joined(separator: "\n")
        #expect(reconstructed == original)
        #expect(DiagnosticLineGroup.groups(in: "").isEmpty)
    }
}
