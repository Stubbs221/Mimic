//
//  CoreTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation
import Testing
@testable import MimicCore

@Suite(.serialized)
struct CoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MimicTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func legacyPrivateActionsCannotExecuteWithoutAProfile() {
        let project = ProjectContext(path: "/tmp/fixture")
        for action in [MimicAction.bootstrap, .localization, .proto, .format, .generation] {
            #expect(throws: MimicError.invalidProject) { try CommandSpec.make(action: action, project: project, options: .standard(), environment: [:]) }
        }
    }

    @Test
    func perActionCapabilitiesAndEnvironment() throws {
        // Arrange
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try "3.3.10\n".write(to: dir.appendingPathComponent(".ruby-version"), atomically: true, encoding: .utf8)
        let project = ProjectContext(path: dir.path, developerDirectory: "/Some Xcode.app/Contents/Developer")
        // Act
        let env = EnvironmentInspector.environment(project: project, base: ["CI": "true", "CUSTOM": "value"], home: "/tmp/home")
        // Assert
        #expect(env["RBENV_VERSION"] == "3.3.10")
        #expect(env["CI"] == nil)
        #expect(env["CUSTOM"] == "value")
        #expect(env["DEVELOPER_DIR"] == project.developerDirectory)
        #expect(env["PATH"]?.hasPrefix(dir.path + "/.gem/bin:") == true)

    }

    @Test(arguments: [
        [:],
        ["LANG": "C"],
        ["LANG": "en_US.UTF-8", "LC_ALL": "C"],
        ["LANG": "C", "LC_CTYPE": "US-ASCII"],
        ["LANG": "ru_RU.UTF-8", "LC_ALL": "POSIX", "LC_CTYPE": "C", "LC_MESSAGES": "C"]
    ])
    func childLocaleOverridesMissingAndConflictingCategories(_ locale: [String: String]) {
        let env = EnvironmentInspector.environment(project: ProjectContext(path: "/tmp/fixture"), base: locale, home: "/tmp/home")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["LC_ALL"] == "en_US.UTF-8")
        #expect(env["LC_CTYPE"] == "en_US.UTF-8")
        // LC_ALL takes precedence over unrelated inherited categories.
        #expect(env["LC_MESSAGES"] == locale["LC_MESSAGES"])
    }

    @Test
    func rubyReadsUTF8SourceWithNormalizedChildLocale() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("fastfile.rb")
        try "desc 'Выгрузить результаты UI-тестов'\nlane :fixture do\nend\n".write(to: source, atomically: true, encoding: .utf8)
        // Compile only: no Fastlane load, lane execution or project mutation.
        let script = "source = File.read(ARGV[0]); RubyVM::InstructionSequence.compile(source); puts Encoding.default_external.name"
        let ascii = EnvironmentInspector.capture("/usr/bin/ruby", ["-e", script, source.path], environment: ["LANG": "C", "LC_ALL": "C", "LC_CTYPE": "C"])
        #expect(ascii.0 != 0)
        let env = EnvironmentInspector.environment(project: ProjectContext(path: dir.path), base: ["LANG": "C", "LC_ALL": "C", "LC_CTYPE": "US-ASCII"], home: dir.path)
        let utf8 = EnvironmentInspector.capture("/usr/bin/ruby", ["-e", script, source.path], directory: dir.path, environment: env)
        #expect(utf8.0 == 0)
        #expect(utf8.1 == "UTF-8")
    }

    @Test
    func queueSerializesAcrossCheckoutsAndRejectsChangedContext() {
        // Arrange
        let first = TaskRecord(action: .localization, project: ProjectContext(path: "/tmp/one", branch: "develop", commit: "one"))
        let second = TaskRecord(action: .proto, project: ProjectContext(path: "/tmp/two"))
        var running = first; running.status = .running
        // Act / Assert
        #expect(QueuePolicy.next(in: [first, second])?.id == first.id)
        #expect(QueuePolicy.next(in: [running, second]) == nil)
        var changed = first.project; changed.branch = "other"
        #expect(!QueuePolicy.matches(changed, request: first.project))
        #expect(QueuePolicy.matches(first.project, request: first.project))
    }

    @Test
    func historyRecoveryRetentionAndPrivateLogs() throws {
        // Arrange
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, limit: 3)
        var records = (0 ..< 4).map { _ in TaskRecord(action: .format, project: ProjectContext(path: "/tmp/project")) }
        for index in 0 ..< 3 {
            records[index].status = .succeeded
        }
        records[3].status = .running
        // Act
        try store.save(records)
        let loaded = try store.load()
        // Assert
        #expect(loaded.count == 3)
        #expect(loaded.last?.status == .interrupted)
        let contents = try String(contentsOf: dir.appendingPathComponent("history.json"), encoding: .utf8)
        #expect(!contents.contains("environment"))
        let log = try BoundedLog(url: dir.appendingPathComponent("bounded.log"), limit: 16)
        try log.append(Data(repeating: 65, count: 32)); log.close()
        #expect(log.truncated)
        #expect(try Data(contentsOf: log.url).count == 16)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PTYTests {
    struct Result { let event: HostEvent?; let output: Data }
    @MainActor
    private func run(_ script: String, input: String? = nil, cancelOn: String? = nil, disconnect: Bool = false, executable: String = "/bin/bash") async throws -> Result {
        let session = PTYSession()
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let command = CommandSpec(executable: executable, arguments: ["-c", script], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
        var collected = Data(); var sent = false
        return try await withCheckedThrowingContinuation { continuation in
            session.onOutput = { bytes in
                collected.append(bytes)
                let output = String(decoding: collected, as: UTF8.self)
                if !sent, let input, output.contains("READY") { sent = true; session.send(Data(input.utf8)) }
                if !sent, let cancelOn, output.contains(cancelOn) { sent = true; if disconnect { session.disconnect() } else { session.cancel() } }
            }
            session.onEvent = { event in if event.kind == "started" { session.resize(columns: 91, rows: 27) } }
            session.onCompletion = { event in continuation.resume(returning: Result(event: event, output: collected)); session.onOutput = nil; session.onCompletion = nil }
            do { try session.start(helper: helper, command: command) } catch { continuation.resume(throwing: error) }
        }
    }

    @Test @MainActor
    func exactExitStatusAndTrailingOutput() async throws {
        // Arrange / Act
        let result = try await run("printf 'terminal tail'; exit 7")
        // Assert
        #expect(result.event?.code == 7)
        #expect(String(decoding: result.output, as: UTF8.self).contains("terminal tail"))
        #expect(result.event?.signal == 0)
    }

    @Test @MainActor
    func failedExecIsNotSuccess() async throws {
        // Arrange / Act
        let result = try await run("", executable: "/missing/MimicExecutable")
        // Assert
        #expect(result.event?.code == 127)
        #expect((result.event?.launchError ?? 0) != 0)
    }

    @Test @MainActor
    func unicodeANSIAndLargeOutput() async throws {
        // Arrange / Act
        let result = try await run("printf '\\033[32mПривет\\033[0m\\n'; /usr/bin/head -c 2097152 /dev/zero; printf END")
        // Assert
        #expect(result.event?.code == 0)
        #expect(result.output.count > 2_097_152)
        #expect(String(decoding: result.output.prefix(100), as: UTF8.self).contains("Привет"))
        #expect(result.output.suffix(3) == Data("END".utf8))
    }

    @Test @MainActor
    func noEchoPasswordAndResize() async throws {
        // Arrange / Act
        let result = try await run("stty -echo; printf READY; read value; stty echo; test \"$value\" = SYNTHETIC_PASSWORD && printf ACCEPTED; stty size", input: "SYNTHETIC_PASSWORD\n")
        // Assert
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(result.event?.code == 0)
        #expect(output.contains("ACCEPTED"))
        #expect(!output.contains("SYNTHETIC_PASSWORD"))
        #expect(output.contains("27 91"))
    }

    @Test @MainActor
    func cancelStopsOwnChildGroup() async throws {
        // Arrange / Act
        let result = try await run("trap 'exit 0' INT TERM; /bin/sleep 90 & child=$!; printf 'READY:%s\\n' \"$child\"; wait", cancelOn: "READY:")
        // Assert
        #expect(result.event?.cancelled == true)
        let output = String(decoding: result.output, as: UTF8.self)
        if let range = output.range(of: "READY:"), let pid = Int32(output[range.upperBound...].prefix(while: { $0.isNumber })) { #expect(kill(pid, 0) != 0 || errno == ESRCH) }
        else { Issue.record("No child PID") }
    }

    @Test @MainActor
    func parentEOFStopsTask() async throws {
        // Arrange / Act
        let result = try await run("printf READY; exec /bin/sleep 90", cancelOn: "READY", disconnect: true)
        // Assert
        #expect(result.event?.cancelled == true)
        #expect(result.event?.signal == Int(SIGINT))
    }

    @Test @MainActor
    func signalIsSeparateFromExitCode() async throws {
        // Arrange / Act
        let result = try await run("kill -TERM $$")
        // Assert
        #expect(result.event?.signal == Int(SIGTERM))
        #expect(result.event?.code == -1)
    }

    @Test @MainActor
    func cancellationInterruptsBlockedPaste() async throws {
        let session = PTYSession()
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let command = CommandSpec(executable: "/bin/bash", arguments: ["-c", "stty -echo -icanon; printf READY; exec /bin/sleep 90"], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"])
        var sent = false
        let began = Date()
        let event: HostEvent? = try await withCheckedThrowingContinuation { continuation in
            session.onOutput = { bytes in
                guard !sent, String(decoding: bytes, as: UTF8.self).contains("READY") else { return }
                sent = true
                session.send(Data(repeating: 65, count: 1024 * 1024))
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    session.cancel()
                }
            }
            session.onCompletion = { event in
                continuation.resume(returning: event)
                session.onCompletion = nil
                session.onOutput = nil
            }
            do { try session.start(helper: helper, command: command) } catch { continuation.resume(throwing: error) }
        }
        #expect(event?.cancelled == true)
        #expect(Date().timeIntervalSince(began) < 5)
    }
}
