//
//  DiagnosticLines.swift
//  MimicCore
//
//  Created by Василий Маслов on 03.10.2026.
import Foundation

/// Consecutive identical lines may be folded for display; the snapshot and prompt stay untouched.
public struct DiagnosticLineGroup: Identifiable, Equatable, Sendable {
    public let firstLine: Int
    public let text: String
    public let count: Int
    public var id: Int { self.firstLine }
    public var canFold: Bool { self.count >= 3 }

    public static func groups(in text: String) -> [Self] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        var groups: [Self] = [], index = 0
        while index < lines.count {
            var end = index + 1
            while end < lines.count, lines[end] == lines[index] {
                end += 1
            }
            groups.append(Self(firstLine: index + 1, text: lines[index], count: end - index)); index = end
        }
        return groups
    }
}
