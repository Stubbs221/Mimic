// Created by Василий Маслов on 16.10.2026.
import Combine
import CryptoKit
import Foundation

/// No cookies, credentials, cache or redirects are shared with arbitrary service origins.
private final class ServiceNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// HTTP requests are independent of the PTY queue. Only metadata receipts survive a restart.
@MainActor public final class ServiceToolCoordinator: ObservableObject {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int, String)
    private struct Receipt: Codable { let owner: String; let fingerprint: String }
    private struct Recent: Codable { let uid: String; let contact: String }
    @Published public private(set) var revision = 0
    public var pendingCount: Int { tasks.count }
    private let defaults: UserDefaults
    private let receiptURL: URL
    private let transport: Transport
    private var receipts: [String: Receipt]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    private var tailIDs: [String: UUID] = [:]
    private var phases: [String: String] = [:]
    private var last: [String: BridgeValue] = [:]
    private var transient: [String: [String: [String: String]]] = [:]
    public init(defaults: UserDefaults = .standard, directory: URL? = nil, transport: @escaping Transport = ServiceToolCoordinator.http) {
        self.defaults = defaults; self.transport = transport
        receiptURL = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mimic/ServiceTools")).appendingPathComponent("receipts.json")
        receipts = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode([String: Receipt].self, from: $0) } ?? [:]
    }

    // MARK: - Per-surface ordinary state

    public static func scope(owner: String, tool: String, context: ServiceToolContext) -> String {
        digest([owner, tool, context.checkout, context.profileRevision, context.namespace].joined(separator: "\n"))
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func state(scope: String) -> BridgeValue {
        let ordinary = defaults.data(forKey: "serviceTool." + scope).flatMap { try? JSONDecoder().decode(BridgeValue.self, from: $0) } ?? .object([:])
        var value = ordinary.object ?? [:]
        var drafts = ordinary["drafts"].object ?? [:]
        for (key, fields) in transient[scope] ?? [:] {
            var form = drafts[key]?.object ?? [:]; for (name, text) in fields { form[name] = .string(text) }; drafts[key] = .object(form)
        }
        value["drafts"] = .object(drafts); value["result"] = last[scope] ?? .null
        return .object(value)
    }
    /// Only declared ordinary fields and validated recent contacts reach disk. UI JSON and secrets do not.
    public func save(scope: String, tool: ServiceTool, uid: String, drafts: [String: [String: String]], clearRecent: Bool = false) throws {
        guard uid.isEmpty || Self.validUID(uid), drafts.count <= 64 else { throw ServiceToolError.arguments }
        var ordinary: [String: BridgeValue] = [:], secrets: [String: [String: String]] = [:]
        for (key, values) in drafts {
            let fields = tool.actions.flatMap { action in action.variants.filter { action.id + ":" + $0.id == key }.map(\.fields) }.first
            guard let fields, Set(values.keys).isSubset(of: Set(fields.map(\.id))), values.values.allSatisfy({ $0.utf8.count <= 4096 }) else { throw ServiceToolError.arguments }
            ordinary[key] = .object(values.filter { key, _ in fields.first(where: { $0.id == key })?.secret != true }.mapValues(BridgeValue.string))
            secrets[key] = values.filter { key, _ in fields.first(where: { $0.id == key })?.secret == true }
        }
        let recent = clearRecent ? BridgeValue.array([]) : state(scope: scope)["recent"]
        defaults.set(try JSONEncoder().encode(BridgeValue.object(["uid": .string(uid), "drafts": .object(ordinary), "recent": recent])), forKey: "serviceTool." + scope)
        transient[scope] = secrets; revision += 1
    }
    public static func validUID(_ uid: String) -> Bool { uid.range(of: #"^[1-9][0-9]{0,19}$"#, options: .regularExpression) != nil && UInt64(uid) != nil }

    // MARK: - Admission and non-replayable execution

    public func start(owner: String, tool: ServiceTool, context: ServiceToolContext, actionID: String, variantID: String, uid: String, values: [String: String], requestID: UUID, stillCurrent: @escaping @MainActor () -> Bool) throws -> BridgeValue {
        guard let action = tool.actions.first(where: { $0.id == actionID }), let variant = action.variants.first(where: { $0.id == variantID }),
              !action.usesUID || Self.validUID(uid), Set(values.keys).isSubset(of: Set(variant.fields.map(\.id))) else { throw ServiceToolError.arguments }
        let scope = Self.scope(owner: owner, tool: tool.id, context: context)
        var parameters: [String: String] = [:]
        for field in variant.fields {
            var value = values[field.id] ?? ""
            if !field.secret { value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if value.isEmpty { value = field.source == "appVersion" ? context.appVersion : field.defaultValue }
            guard field.accepts(value) else { throw ServiceToolError.arguments }
            if !value.isEmpty { parameters[field.id] = value }
        }
        if action.usesUID { parameters["uid"] = uid }
        var endpoint = URLComponents(url: try tool.endpoint(namespace: context.namespace), resolvingAgainstBaseURL: false)!
        endpoint.path = variant.path
        let fields = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: endpoint.url!); request.httpMethod = variant.method; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if ["GET", "DELETE"].contains(variant.method) { endpoint.queryItems = fields; request.url = endpoint.url }
        else {
            var form = URLComponents(); form.queryItems = fields
            request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(context) + encoder.encode(tool) + encoder.encode(parameters)
        let fingerprint = Self.digest(String(decoding: identity, as: UTF8.self) + actionID + "\n" + variantID)
        let id = requestID.uuidString
        if let receipt = receipts[id] {
            guard receipt.owner == scope, receipt.fingerprint == fingerprint else { throw ServiceToolError.duplicate }
            return result(scope: scope, requestID: requestID)
        }
        guard receipts.count < 10000, tasks.count < 100 else { throw ServiceToolError.capacity }
        guard stillCurrent() else { throw ServiceToolError.context }
        var next = receipts; next[id] = Receipt(owner: scope, fingerprint: fingerprint)
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(next).write(to: receiptURL, options: [.atomic]); receipts = next
        phases[id] = "pending"
        let lock = Self.digest(context.namespace + "\n" + tool.baseURLTemplate + "\n" + (action.usesUID ? uid : "create:" + scope))
        let preceding = tails[lock], transport = transport, captured = request
        let operation = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            defer { tasks[requestID] = nil; if tailIDs[lock] == requestID { tails[lock] = nil; tailIDs[lock] = nil }; revision += 1 }
            guard stillCurrent() else { phases[id] = "stale"; return }
            var output: BridgeValue = .null, phase = "success", status = 0
            do {
                let (data, code, contentType) = try await transport(captured); status = code
                guard data.count <= 256 * 1024, contentType.lowercased().contains("json"), let parsed = try? JSONDecoder().decode(BridgeValue.self, from: data) else { throw ServiceToolError.response }
                output = parsed
                guard (200...299).contains(code) else { phase = [400, 401, 403, 404, 409, 422, 429].contains(code) ? "failed" : "unknown"; throw ServiceToolError.response }
                guard parsed["success"] != .bool(false), parsed["error"] == .null || parsed["error"] == .string(""), parsed["detail"] == .null else { phase = "failed"; throw ServiceToolError.response }
                if action.returnsUID { guard Self.validUID(Self.string(parsed["uid"])) else { throw ServiceToolError.response } }
                switch variant.responseKind ?? "object" {
                case "uid": guard Self.validUID(Self.string(parsed["uid"])), !action.usesUID || Self.string(parsed["uid"]) == uid else { throw ServiceToolError.response }
                case "emptyObject": guard parsed.object?.isEmpty == true else { throw ServiceToolError.response }
                case "null": guard parsed == .null else { throw ServiceToolError.response }
                case "resultOK": guard parsed["result"] == .string("ok") else { throw ServiceToolError.response }
                case "code": guard !Self.string(parsed).isEmpty || parsed.object?.isEmpty == false else { throw ServiceToolError.response }
                default: guard parsed.object?.isEmpty == false else { throw ServiceToolError.response }
                }
            } catch {
                if phase == "success" { phase = variant.method == "GET" ? "failed" : "unknown" }
            }
            phases[id] = phase
            let response: BridgeValue = .object(["requestID": .string(id), "phase": .string(phase), "actionID": .string(actionID), "uid": .string(uid), "namespace": .string(context.namespace), "httpStatus": .number(Double(status)), "data": output])
            guard stillCurrent() else { return }
            last[scope] = response
            if phase == "success", action.returnsUID {
                let newUID = Self.string(output["uid"]), old = state(scope: scope)
                let contact = Self.string(output["email"]).isEmpty ? Self.string(output["phone"]) : Self.string(output["email"])
                let known = contact.isEmpty ? parameters["email"] ?? parameters["phone"] ?? "" : contact
                var recent = old["recent"].array ?? []; recent.removeAll { Self.string($0["uid"]) == newUID }
                recent.insert(.object(["uid": .string(newUID), "contact": .string(String(known.prefix(320)))]), at: 0)
                var saved = defaults.data(forKey: "serviceTool." + scope).flatMap { try? JSONDecoder().decode(BridgeValue.self, from: $0) }.flatMap(\.object) ?? [:]
                saved["uid"] = .string(newUID); saved["recent"] = .array(Array(recent.prefix(10)))
                defaults.set(try? encoder.encode(BridgeValue.object(saved)), forKey: "serviceTool." + scope)
            }
        }
        tasks[requestID] = operation; tails[lock] = operation; tailIDs[lock] = requestID; revision += 1
        return result(scope: scope, requestID: requestID)
    }
    public func result(scope: String, requestID: UUID) -> BridgeValue {
        let id = requestID.uuidString
        guard receipts[id]?.owner == scope else { return .object(["phase": .string("unavailable")]) }
        if last[scope]?["requestID"].string == id { return last[scope]! }
        return .object(["requestID": .string(id), "phase": .string(phases[id] ?? "unknown"), "data": .null])
    }
    public static func string(_ value: BridgeValue) -> String { value.string ?? value.integer.map(String.init) ?? "" }

    /// A separate ephemeral session prevents redirect replay and keeps service traffic out of process logs.
    nonisolated public static func http(_ request: URLRequest) async throws -> (Data, Int, String) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: ServiceNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServiceToolError.response }
        var data = Data()
        for try await byte in stream { guard data.count < 256 * 1024 else { throw ServiceToolError.response }; data.append(byte) }
        return (data, response.statusCode, response.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
}
