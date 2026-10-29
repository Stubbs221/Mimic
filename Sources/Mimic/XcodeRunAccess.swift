//
//  XcodeRunAccess.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import MimicCore

/// Native Run verifies the debugger via MCP; toolbar progress is optional and never requests system access.
/// Xcode 26's legacy debug action still needs a toolbar observation to prove that its debugger attached.
enum XcodeRunAccess {
    static func requireDebuggerAccess(native: Bool, hasAccess: () -> Bool) throws {
        guard !native else { return }
        guard hasAccess() else { throw BuildError.xcodeDebuggerAccess }
    }
}
