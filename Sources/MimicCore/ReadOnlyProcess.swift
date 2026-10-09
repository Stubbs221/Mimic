//
//  ReadOnlyProcess.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Darwin
import Foundation

/// A read-only query owns one process group, an absolute deadline and a finite stdout budget.
/// This synchronous API runs on a worker; cancellation is checked between bounded nonblocking reads.
enum ReadOnlyProcess {
    /// Existing short queries retain their eight-second budget. Catalogue callers distinguish timeout from exit failure.
    static let timeoutExitCode: Int32 = -2
    static func capture(_ executable: String, _ arguments: [String], directory: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 8, maximumBytes: Int = 2 * 1024 * 1024) -> (Int32, String) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        guard !Task.isCancelled else { return (-1, "") }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return (-1, "") }
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader); if descriptors[1] >= 0 { close(descriptors[1]) } }
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0, fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else { return (-1, "") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return (-1, "") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return (-1, "") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, reader) == 0,
              posix_spawn_file_actions_addclose(&actions, writer) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { return (-1, "") }
        if let directory, posix_spawn_file_actions_addchdir_np(&actions, directory) != 0 { return (-1, "") }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + env { free(value) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, variables.baseAddress!)
            }
        }
        guard result == 0 else { return (-1, "") }
        // The local writer must close now so EOF describes only the owned group.
        close(writer); descriptors[1] = -1
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var eof = false, status: Int32 = 0, failed = false, reaped = false, timedOut = false
        while !failed {
            if Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline {
                timedOut = !Task.isCancelled; failed = true; break
            }
            if !eof {
                let count = buffer.withUnsafeMutableBytes { read(reader, $0.baseAddress!, $0.count) }
                if count > 0 {
                    guard count <= max(0, maximumBytes - data.count) else { failed = true; break }
                    data.append(contentsOf: buffer.prefix(count)); continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { failed = true; break }
            }
            // Keep the leader unreaped while descendants hold stdout: its PID cannot be reused.
            if eof {
                var info = siginfo_t()
                let exited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if exited == 0 && info.si_pid == pid {
                    // Even descendants which closed stdout must not outlive a completed query.
                    kill(-pid, SIGKILL)
                    reaped = waitpid(pid, &status, 0) == pid; break
                }
                if exited == -1 && errno != EINTR { failed = true; break }
            }
            var descriptor = pollfd(fd: eof ? -1 : reader, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 10)
        }
        if failed {
            kill(-pid, SIGTERM)
            // Escalate before reaping the leader, including inherited pipes and ignored TERM.
            var pause = pollfd(fd: -1, events: 0, revents: 0)
            _ = poll(&pause, 1, 200)
            kill(-pid, SIGKILL)
            let reapDeadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
            while !reaped && DispatchTime.now().uptimeNanoseconds < reapDeadline {
                let exited = waitpid(pid, &status, WNOHANG)
                if exited == pid || exited == -1 && errno == ECHILD { reaped = true; break }
                _ = poll(&pause, 1, 5)
            }
        }
        if !reaped {
            let ownedPID = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(ownedPID, &status, 0) == -1 && errno == EINTR { }
            }
        }
        let code: Int32 = !failed && reaped && status & 0x7f == 0 ? (status >> 8) & 0xff : -1
        return (timedOut ? timeoutExitCode : code, String(decoding: data, as: UTF8.self))
    }
}
