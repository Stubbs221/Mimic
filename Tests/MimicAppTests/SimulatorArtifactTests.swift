//
//  SimulatorArtifactTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MimicCore
@testable import AppleSimulatorMCP

struct SimulatorArtifactTests {
    @Test func fullDisplayPlaneIgnoresSmallerSystemWindowsAndRejectsAmbiguity() throws {
        let portrait = " Window, {{0.0, 0.0}, {834.0, 1194.0}}\n Window, {{0.0, 0.0}, {417.0, 597.0}}"
        let parsed = try SimulatorArtifactReader.geometry(portrait)
        let geometry = try #require(parsed)
        #expect(geometry.0 == 834); #expect(geometry.1 == 1194)
        #expect(try SimulatorArtifactReader.geometry(" Window, {{0.0, 0.0}, {1194.0, 834.0}}\n Window, {{0.0, 0.0}, {834.0, 1194.0}}") == nil)
        #expect(try SimulatorArtifactReader.geometry(" Window, {{0.0, 0.0}, {999999.0, 1.0}}") == nil)
    }
    @Test func pairedNativeFilesAreBoundedAndForeignSymlinkOrGeometryRejected() async throws {
        let id = UUID(), root = FileManager.default.temporaryDirectory.appendingPathComponent("ActionArtifacts/default/DeviceInteractionSynthesize")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stem = "Mimic Simulator " + id.uuidString + "-Fixture"
        let imageURL = root.appendingPathComponent(stem + "-screenshot.png"), hierarchyURL = root.appendingPathComponent(stem + "-hierarchy.txt")
        defer { try? FileManager.default.removeItem(at: imageURL); try? FileManager.default.removeItem(at: hierarchyURL) }
        let context = try #require(CGContext(data: nil, width: 402, height: 874, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage()), bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination)); try (bytes as Data).write(to: imageURL)
        try " Window, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}\n".write(to: hierarchyURL, atomically: true, encoding: .utf8)
        let observation = AppleSimulatorObservation(sessionID: id, revision: 1, applicationState: "Running", screenshot: imageURL, hierarchy: hierarchyURL)
        let frame = try await SimulatorArtifactReader.read(observation)
        #expect(frame.width == 402); #expect(frame.height == 874); #expect(try JSONEncoder().encode(frame.payload).count < MimicSocket.maximumBytes)
        let foreign = AppleSimulatorObservation(sessionID: UUID(), revision: 1, applicationState: "Running", screenshot: imageURL, hierarchy: hierarchyURL)
        await #expect(throws: AppleSimulatorError.invalidResponse) { try await SimulatorArtifactReader.read(foreign) }
        try " Window, {{0.0, 0.0}, {874.0, 402.0}}".write(to: hierarchyURL, atomically: true, encoding: .utf8)
        await #expect(throws: AppleSimulatorError.invalidResponse) { try await SimulatorArtifactReader.read(observation) }
        try FileManager.default.removeItem(at: imageURL); try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: hierarchyURL)
        await #expect(throws: AppleSimulatorError.invalidResponse) { try await SimulatorArtifactReader.read(observation) }
    }
}
