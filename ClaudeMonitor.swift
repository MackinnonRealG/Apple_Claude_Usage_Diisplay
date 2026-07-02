// ClaudeMonitor — a small floating widget showing Claude plan usage limits.
// Reads the OAuth token from the Claude Code keychain entry, calls the same
// usage endpoint the Claude settings screen uses, and renders session/weekly
// bars. Refreshes every 60 seconds. Drag anywhere; position is remembered.

import AppKit
import Foundation

// MARK: - Models

struct UsageRow {
    let key: String
    let label: String
    let percent: Double        // 0-100
    let resetsAt: Date?
}

struct OAuthCreds {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double      // ms since epoch

    var isExpired: Bool { expiresAt / 1000 < Date().timeIntervalSince1970 + 60 }
}

// MARK: - Auth

enum AuthError: Error { case noCredentials, refreshFailed, unauthorized }

final class TokenProvider {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let cacheURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        cacheURL = dir.appendingPathComponent("token.json")
    }

    private func parseCreds(_ data: Data) -> OAuthCreds? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let d = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = d["accessToken"] as? String else { return nil }
        let exp = (d["expiresAt"] as? Double) ?? 0
        let refresh = d["refreshToken"] as? String
        return OAuthCreds(accessToken: access,
                          refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
                          expiresAt: exp)
    }

    private func keychainCreds() -> OAuthCreds? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return parseCreds(out)
    }

    private func cachedCreds() -> OAuthCreds? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return parseCreds(data)
    }

    private func saveCache(_ c: OAuthCreds) {
        var d: [String: Any] = ["accessToken": c.accessToken, "expiresAt": c.expiresAt]
        if let r = c.refreshToken { d["refreshToken"] = r }
        if let data = try? JSONSerialization.data(withJSONObject: d) {
            try? data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: cacheURL.path)
        }
    }

    /// Synchronously refresh an expired token. Returns new creds or nil.
    private func refresh(_ creds: OAuthCreds) -> OAuthCreds? {
        guard let refreshToken = creds.refreshToken,
              let url = URL(string: "https://console.anthropic.com/v1/oauth/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": TokenProvider.clientID,
        ])
        let sem = DispatchSemaphore(value: 0)
        var result: OAuthCreds?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = d["access_token"] as? String else { return }
            let expiresIn = (d["expires_in"] as? Double) ?? 3600
            result = OAuthCreds(accessToken: access,
                                refreshToken: (d["refresh_token"] as? String) ?? refreshToken,
                                expiresAt: (Date().timeIntervalSince1970 + expiresIn) * 1000)
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        if let r = result { saveCache(r) }
        return result
    }

    /// Best available access token, refreshing if possible.
    func token() throws -> String {
        let candidates = [cachedCreds(), keychainCreds()].compactMap { $0 }
        guard !candidates.isEmpty else { throw AuthError.noCredentials }
        // Prefer a live token; among live ones take the latest-expiring.
        if let live = candidates.filter({ !$0.isExpired }).max(by: { $0.expiresAt < $1.expiresAt }) {
            return live.accessToken
        }
        // All expired — try to refresh whichever has a refresh token.
        for c in candidates where c.refreshToken != nil {
            if let fresh = refresh(c) { return fresh.accessToken }
        }
        throw AuthError.refreshFailed
    }

    func invalidateCache() { try? FileManager.default.removeItem(at: cacheURL) }
}

// MARK: - Usage fetching

final class UsageFetcher {
    let tokens = TokenProvider()

    private static let labels: [String: String] = [
        "five_hour": "Current session",
        "seven_day": "Weekly · all models",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_fable": "Weekly · Fable",
        "seven_day_oauth_apps": "Weekly · apps",
    ]
    private static let order = ["five_hour", "seven_day", "seven_day_sonnet",
                                "seven_day_opus", "seven_day_fable"]

    private func prettify(_ key: String) -> String {
        if let l = UsageFetcher.labels[key] { return l }
        var k = key
        if k.hasPrefix("seven_day_") {
            k = String(k.dropFirst("seven_day_".count))
            return "Weekly · " + k.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return k.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func rows(from data: Data) -> [UsageRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        // Preferred: the `limits` array — the same structure the settings screen shows,
        // including per-model rows like Fable/Sonnet under scope.model.display_name.
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            let kindOrder = ["session", "weekly_all", "weekly_scoped"]
            var found: [UsageRow] = []
            for l in limits {
                guard let percent = l["percent"] as? Double else { continue }
                let kind = (l["kind"] as? String) ?? "?"
                let label: String
                switch kind {
                case "session": label = "Current session"
                case "weekly_all": label = "Weekly · all models"
                default:
                    let scope = l["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String)
                        ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
                    label = "Weekly · \(name)"
                }
                found.append(UsageRow(key: kind, label: label,
                                      percent: min(100, max(0, percent)),
                                      resetsAt: parseDate(l["resets_at"] as? String)))
            }
            return found.sorted {
                (kindOrder.firstIndex(of: $0.key) ?? Int.max) <
                (kindOrder.firstIndex(of: $1.key) ?? Int.max)
            }
        }

        // Fallback: older flat shape (five_hour / seven_day / seven_day_<model>).
        var found: [UsageRow] = []
        for (key, value) in root {
            guard key != "extra_usage", let v = value as? [String: Any],
                  let util = v["utilization"] as? Double else { continue }
            found.append(UsageRow(key: key, label: prettify(key),
                                  percent: min(100, max(0, util)),
                                  resetsAt: parseDate(v["resets_at"] as? String)))
        }
        return found.sorted {
            let a = UsageFetcher.order.firstIndex(of: $0.key) ?? Int.max
            let b = UsageFetcher.order.firstIndex(of: $1.key) ?? Int.max
            return a == b ? $0.key < $1.key : a < b
        }
    }

    /// Fetch usage rows; retries once after invalidating the cache on a 401.
    func fetch(completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            self.attempt(retryOn401: true, completion: completion)
        }
    }

    private func attempt(retryOn401: Bool, completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        let accessToken: String
        do { accessToken = try tokens.token() }
        catch { completion(.failure(error)); return }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse, let data = data else {
                completion(.failure(URLError(.badServerResponse))); return
            }
            if http.statusCode == 401 {
                self.tokens.invalidateCache()
                if retryOn401 { self.attempt(retryOn401: false, completion: completion) }
                else { completion(.failure(AuthError.unauthorized)) }
                return
            }
            completion(.success(self.rows(from: data)))
        }.resume()
    }
}

// MARK: - Views

final class BarView: NSView {
    var percent: Double = 0 { didSet { needsLayout = true } }
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.cornerRadius = 3
        fill.cornerRadius = 3
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let color: NSColor = percent >= 90 ? .systemRed
                           : percent >= 75 ? .systemOrange
                           : NSColor(srgbRed: 0.16, green: 0.48, blue: 0.96, alpha: 1)
        fill.backgroundColor = color.cgColor
        let w = bounds.width * CGFloat(percent / 100)
        fill.frame = NSRect(x: 0, y: 0, width: max(percent > 0 ? 6 : 0, w), height: bounds.height)
    }
}

final class WidgetView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let stack = NSStackView()
    let statusLabel = NSTextField(labelWithString: "")
    let fetcher = UsageFetcher()
    var timer: Timer?
    let width: CGFloat = 240
    let frameKey = "ClaudeMonitor.origin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                  reason: "usage monitor")
        buildWindow()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func buildWindow() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let root = WidgetView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        panel.contentView = root

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Monitor", action: #selector(quit), keyEquivalent: "")
        root.menu = menu

        // Restore saved position, else top-right corner.
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - width - 20, y: v.maxY - 160))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: self.frameKey)
        }
        panel.orderFrontRegardless()
        render(rows: [], message: "Loading…")
    }

    @objc func refreshNow() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }

    func refresh() {
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let rows) where !rows.isEmpty:
                    let t = DateFormatter(); t.dateFormat = "h:mm a"
                    self.render(rows: rows, message: "Updated \(t.string(from: Date()))")
                case .success:
                    self.render(rows: [], message: "No usage data returned")
                case .failure(let e):
                    let msg: String
                    switch e {
                    case AuthError.noCredentials, AuthError.refreshFailed, AuthError.unauthorized:
                        msg = "Sign in needed:\nrun  claude auth login  in Terminal"
                    default:
                        msg = "Offline — retrying…"
                    }
                    self.render(rows: nil, message: msg)
                }
            }
        }
    }

    func resetText(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "Resets soon" }
        if secs < 86400 {
            let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
            return h > 0 ? "Resets in \(h) hr \(m) min" : "Resets in \(m) min"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }

    /// rows == nil keeps nothing but the message (error state);
    /// rows == [] with a message shows header + message.
    func render(rows: [UsageRow]?, message: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "Claude usage")
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = NSColor(white: 1, alpha: 0.9)
        stack.addArrangedSubview(title)

        for row in rows ?? [] {
            let head = NSStackView()
            head.orientation = .horizontal
            head.distribution = .fill
            let name = NSTextField(labelWithString: row.label)
            name.font = .systemFont(ofSize: 10.5, weight: .medium)
            name.textColor = NSColor(white: 1, alpha: 0.85)
            let pct = NSTextField(labelWithString: "\(Int(row.percent.rounded()))%")
            pct.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            pct.textColor = NSColor(white: 1, alpha: 0.85)
            head.addArrangedSubview(name)
            head.addArrangedSubview(NSView())
            head.addArrangedSubview(pct)
            head.translatesAutoresizingMaskIntoConstraints = false

            let bar = BarView(frame: .zero)
            bar.percent = row.percent
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let reset = NSTextField(labelWithString: resetText(row.resetsAt))
            reset.font = .systemFont(ofSize: 9)
            reset.textColor = NSColor(white: 1, alpha: 0.45)

            let group = NSStackView(views: [head, bar, reset])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 3
            stack.addArrangedSubview(group)
            head.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            bar.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            group.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
        }

        let status = NSTextField(wrappingLabelWithString: message)
        status.font = .systemFont(ofSize: 9)
        status.textColor = NSColor(white: 1, alpha: 0.4)
        status.preferredMaxLayoutWidth = width - 28
        stack.addArrangedSubview(status)

        let h = stack.fittingSize.height
        let origin = panel.frame.origin
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: width, height: h))
        panel.setFrameOrigin(NSPoint(x: origin.x, y: top - h))  // keep top edge fixed
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
