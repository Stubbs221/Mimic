// Created by Василий Маслов on 06.10.2026.
import AppKit
import MimicCore

/// One private subscription keeps replay cursors separate from the native SwiftTerm view.
@MainActor final class PanelTerminalSubscription {
    let channel: PanelTerminalChannel
    var last = Data()
    var snapshot: Data
    var buildCursor = 0
    private(set) var hasOutput = false
    private var stopped = false
    private weak var model: TaskCoordinator?
    init(_ channel: PanelTerminalChannel, model: TaskCoordinator) {
        self.channel = channel; self.model = model
        self.snapshot = Data(model.terminalSnapshot(id: channel.taskID).suffix(128 * 1024)); self.hasOutput = !self.snapshot.isEmpty
        model.attachTerminal(owner: channel.id) { [weak self] id, bytes in
            guard let self, !self.stopped, id == self.channel.taskID else { return }
            self.hasOutput = self.hasOutput || !bytes.isEmpty
            self.snapshot.append(bytes); self.snapshot = Data(self.snapshot.suffix(128 * 1024))
        }
    }
    func received(_ bytes: Data) { self.hasOutput = self.hasOutput || !bytes.isEmpty }
    /// Releases replay allocations and this observer only; it never closes the shared PTY.
    func stop() {
        guard !self.stopped else { return }
        self.stopped = true; self.model?.detachTerminal(owner: self.channel.id); self.model = nil
        self.snapshot = Data(); self.last = Data()
    }
}

extension MimicIntegration {
    // MARK: - Terminal subscription lifetime

    /// Removing every expired observer in one commit avoids one timer task per subscription.
    func expireTerminalChannels(now: Date = .now) {
        let expired = self.terminalChannels.filter { $0.value.channel.expiresAt <= now }
        guard !expired.isEmpty else { return }
        for subscription in expired.values { subscription.stop() }
        self.terminalChannels = self.terminalChannels.filter { $0.value.channel.expiresAt > now }
    }

    /// The earliest deadline owns cleanup even after a silent disconnect and without bridge traffic.
    /// Polling does not renew the channel's cryptographic 15-minute lifetime.
    func scheduleTerminalExpiry() {
        let deadline = self.terminalChannels.values.map { $0.channel.expiresAt }.min()
        guard deadline != self.terminalExpiryDeadline else { return }
        self.terminalExpiryTask?.cancel(); self.terminalExpiryTask = nil; self.terminalExpiryDeadline = deadline
        guard let deadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        self.terminalExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.terminalExpiryTask = nil; self.terminalExpiryDeadline = nil
            self.expireTerminalChannels()
            // Recompute if the wall clock moved back or sleep resumed just before the boundary.
            if self.terminalExpiryTask == nil { self.scheduleTerminalExpiry() }
        }
    }

    // MARK: - Private terminal transport

    /// Ciphertext is the only terminal payload crossing MCP; task ownership is checked on every message.
    func terminalRequest(_ request: MimicBridgeRequest, threadID: String) async throws -> BridgeValue {
        let p = request.parameters
        self.expireTerminalChannels()
        if request.method == "panel_terminal_open" || request.method == "panel_secret_input" {
            guard let id = p["taskID"]?.string.flatMap(UUID.init(uuidString:)), let project = project(threadID),
                  model.records.contains(where: { $0.id == id && $0.project.path == project.path }) || model.builds.records.contains(where: { $0.id == id && $0.project.path == project.path }) else { throw failure("notFound") }
            if request.method == "panel_secret_input" {
                guard model.activeID == id || model.builds.canInput(id) else { throw failure("notFound") }
                let alert = NSAlert(); alert.messageText = text("panel.secret.title")
                let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); alert.accessoryView = input
                defer { input.stringValue = "" }
                alert.addButton(withTitle: text("send")); alert.addButton(withTitle: text("cancel"))
                if NativeRetroDialog.run(alert, store: model.appearance) == .alertFirstButtonReturn {
                    defer { input.stringValue = "" }
                    let bytes = Data((input.stringValue + "\n").utf8)
                    if model.activeID == id {
                        guard model.input(id: id, data: bytes) else { throw failure("terminalInput") }
                    } else { try await model.builds.privateInput(id, bytes: bytes) }
                }
                input.stringValue = ""; return .object(["done": .bool(true)])
            }
            guard terminalChannels.count < 32, let encoded = p["publicKey"]?.string, let key = Data(base64Encoded: encoded) else { throw failure("arguments") }
            let channel = try PanelTerminalChannel(taskID: id, threadID: threadID, clientKey: key)
            terminalChannels[channel.id] = PanelTerminalSubscription(channel, model: model)
            return .object(["channelID": .string(channel.id.uuidString), "taskID": .string(id.uuidString), "threadID": .string(threadID), "publicKey": .string(channel.publicKey.base64EncodedString()), "expiresAt": .string(channel.expiresAt.ISO8601Format())])
        }
        guard let id = p["channelID"]?.string.flatMap(UUID.init(uuidString:)), let subscription = terminalChannels[id], subscription.channel.threadID == threadID else { throw failure("channel") }
        let channel = subscription.channel
        if request.method == "panel_terminal_close" { subscription.stop(); terminalChannels[id] = nil; return .object(["closed": .bool(true)]) }
        guard let current = project(threadID), model.records.contains(where: { $0.id == channel.taskID && $0.project.path == current.path }) || model.builds.records.contains(where: { $0.id == channel.taskID && $0.project.path == current.path }) else { throw failure("context") }
        if request.method == "panel_terminal_send" {
            let packet = try JSONDecoder().decode(PanelCiphertext.self, from: JSONEncoder().encode(p["packet"]!))
            let payload = try JSONDecoder().decode([String: BridgeValue].self, from: channel.open(packet, threadID: threadID, taskID: channel.taskID))
            guard Set(payload.keys).isSubset(of: ["input", "columns", "rows"]), model.activeID == channel.taskID || model.builds.canInput(channel.taskID) else { throw failure("arguments") }
            if let input = payload["input"]?.string {
                guard input.utf8.count <= 8192 else { throw failure("arguments") }
                if model.activeID == channel.taskID {
                    guard model.input(id: channel.taskID, data: Data(input.utf8)) else { throw failure("terminalInput") }
                } else { try await model.builds.privateInput(channel.taskID, bytes: Data(input.utf8)) }
            }
            if let columns = payload["columns"]?.integer, let rows = payload["rows"]?.integer {
                guard (10...500).contains(columns), (2...200).contains(rows) else { throw failure("arguments") }
                if model.activeID == channel.taskID { model.resize(id: channel.taskID, columns: columns, rows: rows) }
                else { model.builds.resize(channel.taskID, columns: columns, rows: rows) }
            }
            return .object(["accepted": .bool(true)])
        }
        guard request.method == "panel_terminal_poll" else { throw failure("arguments") }
        let output: Data, reset: Bool
        if model.builds.records.contains(where: { $0.id == channel.taskID }) {
            let slice = try model.builds.readLog(channel.taskID, after: subscription.buildCursor, privateChannel: true)
            subscription.buildCursor = slice.nextCursor; output = Data(slice.text.utf8); reset = slice.gap
        } else {
            let snapshot = subscription.snapshot
            reset = !snapshot.starts(with: subscription.last)
            output = reset ? snapshot : snapshot.dropFirst(subscription.last.count)
            subscription.last = snapshot
        }
        subscription.received(output)
        let payload: BridgeValue = .object(["bytes": .string(output.base64EncodedString()), "reset": .bool(reset), "canInput": .bool(model.activeID == channel.taskID || model.builds.canInput(channel.taskID)), "outputAvailable": .bool(subscription.hasOutput), "finished": .bool(model.records.first(where: { $0.id == channel.taskID }).map { $0.status != .queued && $0.status != .running } ?? model.builds.records.first(where: { $0.id == channel.taskID }).map { !$0.canCancel } ?? false)])
        let result = try BridgeValue.encode(channel.seal(JSONEncoder().encode(payload)))
        if model.records.first(where: { $0.id == channel.taskID }).map({ $0.hasPrivateInput == true && $0.status != .queued && $0.status != .running }) == true {
            subscription.stop()
        }
        return result
    }
}
