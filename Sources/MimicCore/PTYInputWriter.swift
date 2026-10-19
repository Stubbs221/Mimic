//
//  PTYInputWriter.swift
//  MimicCore
//
//  Created by Василий Маслов on 12.10.2026.
import Darwin
import Foundation

/// Owns a nonblocking pipe descriptor. The lock protects admission, frames and source suspension;
/// dispatch handlers never wait for a reader and never capture an input payload per queued task.
final class PTYInputWriter: @unchecked Sendable {
    static let byteBudget = 4 * 1024 * 1024
    static let frameBudget = 256
    private struct Frame {
        let kind: UInt8
        var data: Data
        var offset = 0
    }
    private let lock = NSLock()
    private let source: DispatchSourceWrite
    private let descriptor: Int32
    private var frames: [Frame] = []
    private var inputBytes = 0
    private var inputFrames = 0
    private var suspended = true
    private var stopped = false

    init(fileDescriptor: Int32) throws {
        let descriptor = dup(fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            let code = errno; Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
        self.source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "Mimic.pty.input"))
        self.source.setEventHandler { [weak self] in self?.writeAvailable() }
        // Closing only after cancellation handlers drain prevents descriptor reuse during a write.
        self.source.setCancelHandler { Darwin.close(descriptor) }
    }

    deinit { self.stop() }

    /// False rejects the entire payload before framing or copying it. Accepted frames remain FIFO.
    func enqueue(_ payload: Data) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.stopped, payload.count <= 1024 * 1024 else { return false }
        if payload.isEmpty { return true }
        let bytes = payload.count + 5
        guard self.inputBytes <= Self.byteBudget - bytes, self.inputFrames < Self.frameBudget else { return false }
        self.frames.append(Self.frame(kind: 1, payload: payload))
        self.inputBytes += bytes; self.inputFrames += 1
        self.resumeLocked()
        return true
    }

    /// At most one unwritten resize survives; a partially written control frame must finish intact.
    func resize(_ payload: Data) {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.stopped else { return }
        let frame = Self.frame(kind: 2, payload: payload)
        if let index = self.frames.lastIndex(where: { $0.kind == 2 && $0.offset == 0 }) {
            self.frames[index] = frame
        } else { self.frames.append(frame) }
        self.resumeLocked()
    }

    /// Testable metadata only: full frame allocations stay charged until their last byte is written.
    var pending: (bytes: Int, frames: Int, resizes: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        return (self.inputBytes, self.inputFrames, self.frames.filter { $0.kind == 2 }.count)
    }

    /// Discards pending input and schedules EOF independently of admission or pipe capacity.
    func stop() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.stopLocked()
    }

    // MARK: - Nonblocking delivery

    private static func frame(kind: UInt8, payload: Data) -> Frame {
        let size = UInt32(payload.count)
        var data = Data([kind, UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        data.append(payload)
        return Frame(kind: kind, data: data)
    }

    private func resumeLocked() {
        if self.suspended { self.suspended = false; self.source.resume() }
    }

    private func stopLocked() {
        guard !self.stopped else { return }
        self.stopped = true
        self.frames.removeAll(); self.inputBytes = 0; self.inputFrames = 0
        self.resumeLocked(); self.source.cancel()
    }

    private func writeAvailable() {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.stopped, !self.frames.isEmpty else { return }
        let offset = self.frames[0].offset
        let count = self.frames[0].data.withUnsafeBytes {
            Darwin.write(self.descriptor, $0.baseAddress!.advanced(by: offset), min(64 * 1024, $0.count - offset))
        }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { self.stopLocked(); return }
        self.frames[0].offset += count
        if self.frames[0].offset == self.frames[0].data.count {
            let frame = self.frames.removeFirst()
            if frame.kind == 1 { self.inputBytes -= frame.data.count; self.inputFrames -= 1 }
        }
        if self.frames.isEmpty { self.suspended = true; self.source.suspend() }
    }
}
