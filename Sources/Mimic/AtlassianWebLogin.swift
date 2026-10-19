// Created by Василий Маслов on 13.10.2026.
import AppKit
import WebKit
import MimicCore
import Observation

/// User-driven SSO uses an isolated ephemeral browser; only service-origin cookies are persisted.
@MainActor final class AtlassianWebLogin: NSObject, NSWindowDelegate {
    private let preset: AtlassianPreset
    private let keychain: AtlassianKeychain
    private var services: [(String, URL)]
    private var window: NSWindow?
    private let web: WKWebView
    private var timer: Timer?
    private var checking = false
    private var deadline = Date()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var label: NSTextField?
    private let appearance: PanelAppearanceStore?
    private var chrome: NativeRetroWindowAdapter?
    private var verifiedSessions: [String: Data] = [:]

    init(preset: AtlassianPreset, keychain: AtlassianKeychain, appearance: PanelAppearanceStore? = nil) {
        self.appearance = appearance
        self.preset = preset; self.keychain = keychain
        services = [("jira", preset.jiraURL), ("confluence", preset.confluenceURL)].compactMap { service, raw in raw.flatMap(URL.init(string:)).map { (service, $0) } }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); self.web = WKWebView(frame: .zero, configuration: config)
        super.init()
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; self.deadline = Date().addingTimeInterval(600)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = text("work.login") + " · " + preset.title; window.isReleasedWhenClosed = false; window.delegate = self; self.window = window
                let stack = NSStackView(); stack.orientation = .vertical; stack.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12); stack.spacing = 10
                let label = NSTextField(wrappingLabelWithString: text("work.login.instructions")); self.label = label; stack.addArrangedSubview(label); stack.addArrangedSubview(web); window.contentView = stack
                NSLayoutConstraint.activate([web.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24), web.heightAnchor.constraint(greaterThanOrEqualToConstant: 500)])
                chrome = NativeRetroWindowAdapter(window: window, store: appearance); observeAppearance()
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); next()
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check() } }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(AtlassianError.cancelled)) } }
    }
    private func next() {
        guard let (service, base) = services.first else {
            do { try keychain.writeRESTSessions(verifiedSessions); finish(.success(())) }
            catch { finish(.failure(error)) }
            return
        }
        label?.stringValue = service.capitalized + " · " + text("work.login.instructions")
        let path = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (service == "jira" ? "/secure/Dashboard.jspa" : "/")
        web.load(URLRequest(url: URL(string: path)!))
    }
    /// Only host labels/chrome change; the nonpersistent authentication WebView stays retained.
    private func observeAppearance() {
        guard let appearance else { return }
        let choice = withObservationTracking { appearance.selection } onChange: { [weak self] in DispatchQueue.main.async { self?.observeAppearance() } }
        label?.font = choice.isRetro ? NativeRetro.font(choice) : .systemFont(ofSize: 13)
        label?.textColor = choice.isRetro ? NativeRetro.color("ink", appearance: choice) : .labelColor
    }
    private func check() async {
        guard !checking, continuation != nil, let (service, base) = services.first else { return }
        if Date() > deadline { finish(.failure(AtlassianError.authenticationRequired)); return }
        checking = true; defer { checking = false }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies().filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == base.host?.lowercased() }
        guard !cookies.isEmpty else { return }
        let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        let client = AtlassianREST(preset: preset, headers: [service: ["Cookie": header]])
        guard (try? await client.verifyIdentity(service)) != nil else { return }
        guard continuation != nil else { return }
        do { verifiedSessions[service] = try JSONEncoder().encode(cookies.map(AtlassianCookie.init)); services.removeFirst(); next() }
        catch { finish(.failure(error)) }
    }
    func windowWillClose(_ notification: Notification) { finish(.failure(AtlassianError.cancelled)) }
    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }; self.continuation = nil; verifiedSessions = [:]; timer?.invalidate(); timer = nil; window?.delegate = nil; window?.close(); window = nil
        continuation.resume(with: result)
    }
}
