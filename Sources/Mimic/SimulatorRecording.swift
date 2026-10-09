//
//  SimulatorRecording.swift
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import AVFoundation
import Foundation
import MimicCore

/// Muxes existing native AVCC packets. Recording is explicit and bounded; no screen capture API is used.
@MainActor final class SimulatorRecording {
    let path: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMVideoFormatDescription?
    private var configuration: Data?
    private var firstTimestamp: UInt64?
    private var sequence: UInt64?
    private var frames = 0, dropped = 0
    private var bytes = 0
    private var error: String?
    private var stopped = false
    private var needsKeyframe = true
    private let started = Date()
    init(path: URL) { self.path = path }
    func append(_ packet: Data) {
        guard !stopped, error == nil else { return }
        guard packet.count >= 27, packet.count <= 512_000, bytes < 256 * 1024 * 1024, Date().timeIntervalSince(started) < 300 else { error = "recordingLimit"; return }
        func number(_ start: Int, _ length: Int) -> UInt64 { packet[start..<start + length].reduce(0) { $0 << 8 | UInt64($1) } }
        let nextSequence = number(1, 8), timestamp = number(9, 8), length = Int(number(25, 2))
        guard length <= packet.count - 27 else { error = "videoPacketInvalid"; return }
        if let sequence, nextSequence != sequence &+ 1 { dropped += Int(min(nextSequence > sequence ? nextSequence - sequence - 1 : 1, 100_000)); needsKeyframe = true }
        sequence = nextSequence
        do {
            if length > 0 {
                let config = Data(packet[27..<27 + length])
                if let configuration, configuration != config { error = "recordingFormatChanged"; return }
                if writer == nil {
                    guard packet[0] == 1 else { return }
                    try configure(config); firstTimestamp = timestamp
                }
            }
            guard let writer, let input, let format, let firstTimestamp else { return }
            guard timestamp >= firstTimestamp, writer.status == .writing else { error = "recordingWriter"; return }
            if needsKeyframe && packet[0] != 1 { return }
            guard packet.count > 27 + length, timestamp - firstTimestamp <= UInt64(Int64.max) else { error = "videoPacketInvalid"; return }
            let sampleBytes = Data(packet[(27 + length)...])
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sampleBytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: sampleBytes.count, flags: 0, blockBufferOut: &block) == noErr, let block else { error = "recordingWriter"; return }
            let copied = sampleBytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sampleBytes.count) }
            guard copied == noErr else { error = "recordingWriter"; return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(timestamp - firstTimestamp), timescale: 1_000_000), decodeTimeStamp: .invalid)
            var size = sampleBytes.count, sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { error = "recordingWriter"; return }
            guard input.isReadyForMoreMediaData else { dropped += 1; needsKeyframe = true; return }
            guard input.append(sample) else { error = "recordingWriter"; return }
            needsKeyframe = false; frames += 1; bytes += packet.count
        } catch { self.error = "recordingWriter" }
    }
    private func configure(_ config: Data) throws {
        guard config.count >= 8 else { throw BuildError.arguments }
        let spsLength = Int(config[6]) << 8 | Int(config[7])
        guard spsLength > 0, 9 + spsLength + 2 <= config.count else { throw BuildError.arguments }
        let ppsStart = 9 + spsLength
        let ppsLength = Int(config[ppsStart]) << 8 | Int(config[ppsStart + 1])
        guard ppsLength > 0, ppsStart + 2 + ppsLength <= config.count else { throw BuildError.arguments }
        let sps = Data(config[8..<8 + spsLength]), pps = Data(config[ppsStart + 2..<ppsStart + 2 + ppsLength])
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
            let pointers = [a.baseAddress!.assumingMemoryBound(to: UInt8.self), b.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        } }
        guard status == noErr, let description else { throw BuildError.arguments }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let writer = try AVAssetWriter(outputURL: path, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw BuildError.unavailable }; writer.add(input)
        guard writer.startWriting() else { throw BuildError.unavailable }; writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; format = description; configuration = config
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func finish(interrupted: Bool = false) async -> SimulatorRecordingResult {
        stopped = true; input?.markAsFinished()
        if let writer, writer.status == .writing { await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } } }
        let succeeded = writer?.status == .completed && frames > 0 && error == nil && !interrupted && dropped == 0
        return .init(path: path.path, frames: frames, droppedFrames: dropped, status: succeeded ? "completed" : "incomplete", error: error ?? (interrupted ? "interrupted" : frames == 0 ? "noFrames" : dropped > 0 ? "droppedFrames" : writer?.status != .completed ? "recordingWriter" : nil))
    }
}
