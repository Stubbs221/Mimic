//
//  TerminalInputPromptDetector.swift
//  MimicCore
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation

/// Recognizes common interactive CLI prompts across PTY chunks without persisting terminal content.
public struct TerminalInputPromptDetector: Sendable {
    private var tail = Data()
    private static let patterns = [
        #"(?i)(?:^|[\s\]])(?:password|passphrase|username|apple id|verification code|authentication code|security code|one.time code|2fa code|пароль|код подтверждения)\b[^\r\n]{0,160}[:?>]\s*$"#,
        #"(?i)(?:^|[\s\]])(?:please\s+)?(?:enter|provide|type|select|choose|введите|выберите)\b[^\r\n]{0,160}[:?>]\s*$"#,
        #"(?i)(?:\[(?:y/n|n/y|yes/no|no/yes)\]|\((?:y/n|n/y|yes/no|no/yes)\))\s*[:?>]?\s*$"#,
        #"(?i)\bpress (?:any key|enter|return) (?:to continue|to proceed)[.!…\s]*$"#
    ].map { try! NSRegularExpression(pattern: $0) }

    public init() { }

    /// Only the most recent visible line is considered; mentions in preceding logs are not prompts.
    public mutating func consume(_ bytes: Data) -> Bool {
        self.tail.append(bytes.suffix(4096))
        if self.tail.count > 4096 { self.tail = Data(self.tail.suffix(4096)) }
        let visible = DiagnosticText.visible(String(decoding: self.tail, as: UTF8.self))
        let line = visible.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return Self.patterns.contains { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
    }

    /// Accepted terminal input consumes the prompt; a rejected send must leave it intact.
    public mutating func reset() { self.tail.removeAll(keepingCapacity: false) }
}
