//
//  AgentRecordingTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import AVFoundation
@preconcurrency import VideoToolbox
import Testing
@testable import Mimic

/// VideoToolbox completes callbacks before CompleteFrames returns. Only Data crosses that boundary.
private final class AgentPacketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var packet: Data? { lock.lock(); defer { lock.unlock() }; return value }
    func capture(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
            sets.append(Data(bytes: pointer, count: size))
        }
        let sps = sets[0], pps = sets[1]; guard sps.count > 3 else { return }
        func be<T: FixedWidthInteger>(_ number: T) -> Data { var number = number.bigEndian; return withUnsafeBytes(of: &number) { Data($0) } }
        var config = Data([1, sps[1], sps[2], sps[3], 255, 225]); config += be(UInt16(sps.count)); config += sps; config += Data([1]); config += be(UInt16(pps.count)); config += pps
        var encoded = Data(count: CMBlockBufferGetDataLength(block))
        guard encoded.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }) == noErr else { return }
        var packet = Data([1]); packet += be(UInt64(1)); packet += be(UInt64(1_000_000)); packet += be(UInt32(32)); packet += be(UInt32(32)); packet += be(UInt16(config.count)); packet += config; packet += encoded
        lock.lock(); value = packet; lock.unlock()
    }
}
@MainActor struct AgentRecordingTests {
    @Test func nativeAVCCPacketProducesReadableMovieAndNoFramesNeverPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentRecording-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = await SimulatorRecording(path: root.appendingPathComponent("empty.mov")).finish()
        #expect(empty.status == "incomplete" && empty.error == "noFrames")
        let box = AgentPacketFixture(); var encoder: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: nil, width: 32, height: 32, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
            if status == noErr, let ref, let sample { Unmanaged<AgentPacketFixture>.fromOpaque(ref).takeUnretainedValue().capture(sample) }
        }, refcon: Unmanaged.passUnretained(box).toOpaque(), compressionSessionOut: &encoder)
        try #require(created == noErr); let session = try #require(encoder); defer { VTCompressionSessionInvalidate(session) }
        var image: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess)
        let buffer = try #require(image); CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
        try #require(VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 30), frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
        try #require(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr)
        let packet = try #require(box.packet), path = root.appendingPathComponent("fixture.mov")
        let recording = SimulatorRecording(path: path); recording.append(packet)
        let result = await recording.finish(); #expect(result.status == "completed" && result.frames == 1)
        let tracks = try await AVURLAsset(url: path).loadTracks(withMediaType: .video); #expect(tracks.count == 1)
        let malformed = SimulatorRecording(path: root.appendingPathComponent("bad.mov")); malformed.append(Data([1]))
        #expect(await malformed.finish().error == "recordingLimit")
    }
}
