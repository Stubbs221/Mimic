//
//  BootstrapMintInstallation.swift
//  MimicCore
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation

/// An explicitly approved Bootstrap prerequisite, executed by the existing local FIFO and PTY.
public enum BootstrapMintInstallation {
    /// Validates the pinned profile first; only a missing Mint may be deferred until installation.
    public static func command(execution: ProfileExecution, project: ProjectContext, environment: [String: String]) throws -> CommandSpec {
        guard execution.binding?.role == .bootstrap else { throw ProfileError.action }
        do { _ = try execution.commands(project: project, environment: environment) }
        catch MimicError.missingTools(let tools) where Set(tools) == ["mint"] { }
        guard let brew = EnvironmentInspector.executable("brew", environment: environment) else { throw MimicError.missingTools(["brew"]) }
        return CommandSpec(executable: brew, arguments: ["install", "mint"], directory: project.path, environment: environment)
    }
}
