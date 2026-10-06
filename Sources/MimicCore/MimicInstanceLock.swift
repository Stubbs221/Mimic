//
//  MimicInstanceLock.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Darwin
import Foundation

/// Owns the native app's per-user lock, independent of its bundle path or launch source.
/// Retain it for the entire app lifetime. The kernel releases it on exit, including a crash.
public final class MimicInstanceLock {
    public static var path: String {
        URL(fileURLWithPath: MimicSocket.path).deletingLastPathComponent().appendingPathComponent("native-instance.lock").path
    }

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Returns nil only when another process owns the lock; filesystem errors must stop launch.
    /// The file is deliberately never removed: unlinking would let contenders lock different inodes.
    public static func acquire(path: String = MimicInstanceLock.path) throws -> MimicInstanceLock? {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // TaskHost and other exec'd helpers must not keep the application lock alive.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return MimicInstanceLock(descriptor: descriptor)
    }

    deinit { close(self.descriptor) }
}
