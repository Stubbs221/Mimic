//
//  MimicApplicationLaunchTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Testing
@testable import Mimic

struct MimicApplicationLaunchTests {
    @Test(arguments: [
        ([], MimicApplicationLaunch.panel),
        (["--show-tasks"], .tasks),
        (["--setup"], .setup),
        (["--setup", "--uninstall-integration"], .uninstall),
        (["--mcp-background"], .background),
        (["--mcp-background", "--show-tasks"], .tasks)
    ])
    func preservesLaunchIntent(arguments: [String], expected: MimicApplicationLaunch) {
        #expect(MimicApplicationLaunch(arguments: arguments) == expected)
    }
}
