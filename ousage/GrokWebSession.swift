//
//  GrokWebSession.swift
//  ousage
//

import AppKit
import Foundation
import SQLite3
import WebKit

/// SuperGrok limits as grok.com reports them to its own usage meter.
nonisolated struct GrokWebUsage: Sendable {
    /// The weekly usage pool shared across chat, Imagine and voice. Missing for plans without one.
    let pool: CodexUsageWindow?
}

/// grok.com sits behind a Cloudflare check that only a real browser engine passes, so requests
/// run inside a WebKit page on grok.com. The first pass needs a visible window; Cloudflare's
/// clearance is then kept in ousage's own website data, and later checks run hidden.
@MainActor
final class GrokWebSession: NSObject {
    private static let challengeTitle = "Just a moment..."

    private let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C2B0E-5A3D-4C1E-9B7A-1D2E3F405162")!)
    private var verifyWindow: NSWindow?
    private var verifyTimer: Timer?
    private var isCheckingVerification = false

    /// Checks usage without showing anything.
    func fetch() async throws -> GrokWebUsage {
        await seedBrowserCookies()

        let page = HiddenPage(dataStore: dataStore)
        defer { page.close() }

        // A tiny same-origin page is enough to make requests with grok.com's cookies.
        try await page.load(URL(string: "https://grok.com/robots.txt")!)
        if page.webView.title == Self.challengeTitle {
            throw GrokWebError.needsVerification
        }
        return try await Self.query(page.webView)
    }

    /// Opens grok.com in a window so Cloudflare (and sign-in, if needed) can complete,
    /// then closes it once usage can be read.
    func verify(onSuccess: @escaping @MainActor () -> Void) {
        if let verifyWindow {
            verifyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        Task {
            await seedBrowserCookies()

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: configuration)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Grok — ousage"
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.center()
            window.delegate = self
            verifyWindow = window

            webView.load(URLRequest(url: URL(string: "https://grok.com/")!))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // Waits out Cloudflare and any sign-in, then hands back to the menu bar.
            verifyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isCheckingVerification,
                          !webView.isLoading, webView.title != Self.challengeTitle else { return }
                    self.isCheckingVerification = true
                    Task {
                        defer { self.isCheckingVerification = false }
                        guard (try? await Self.query(webView)) != nil, self.verifyWindow != nil else { return }
                        self.closeVerifyWindow()
                        onSuccess()
                    }
                }
            }
        }
    }

    private func closeVerifyWindow() {
        verifyTimer?.invalidate()
        verifyTimer = nil
        verifyWindow?.delegate = nil
        verifyWindow?.close()
        verifyWindow = nil
    }

    /// Fetches the usage pool from inside the page.
    private static func query(_ webView: WKWebView) async throws -> GrokWebUsage {
        let script = """
        const credits = await fetch("/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig", {
          method: "POST",
          headers: {"content-type": "application/grpc-web+proto", "x-grpc-web": "1"},
          body: new Uint8Array([0, 0, 0, 0, 0]),
        });
        const creditBytes = new Uint8Array(await credits.arrayBuffer());
        let creditsBase64 = "";
        for (const byte of creditBytes) creditsBase64 += String.fromCharCode(byte);
        return {creditsStatus: credits.status, credits: btoa(creditsBase64)};
        """

        let result = try await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .defaultClient)
        guard let object = result as? [String: Any],
              let creditsStatus = (object["creditsStatus"] as? NSNumber)?.intValue else {
            throw GrokWebError.invalidResponse
        }

        switch creditsStatus {
        case 200..<300:
            break
        case 401:
            throw GrokWebError.signedOut
        case 403:
            throw GrokWebError.needsVerification
        default:
            throw GrokWebError.serverError(creditsStatus)
        }

        guard let base64 = object["credits"] as? String, let data = Data(base64Encoded: base64) else {
            throw GrokWebError.invalidResponse
        }
        return GrokWebUsage(pool: parseCreditsConfig(data))
    }

    /// Reads `GetGrokCreditsConfigResponse` out of its gRPC-web frame. Field numbers come from
    /// grok.com's `grok_api_v2` descriptor: config = 1; in config, credit_usage_percent = 1 (float),
    /// current_period = 8 (type = 1, start = 2, end = 3), is_unified_billing_user = 11.
    private static func parseCreditsConfig(_ data: Data) -> CodexUsageWindow? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == 0 else { return nil }
        let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes.count >= 5 + length,
              let config = ProtobufReader(bytes[5..<(5 + length)]).message(1) else {
            return nil
        }

        let reader = ProtobufReader(config)
        // Plans billed the old way have no shared pool, and grok.com shows no meter for them.
        guard reader.varint(11) == 1 else { return nil }

        // proto3 leaves out zero, so a missing percentage means nothing used yet.
        let percent = reader.float(1).map(Double.init) ?? 0
        let period = reader.message(8).map(ProtobufReader.init)
        let start = period?.message(2).map(ProtobufReader.init).flatMap(timestamp)
        let end = period?.message(3).map(ProtobufReader.init).flatMap(timestamp)
        let windowMinutes: Double = if let start, let end, end > start {
            end.timeIntervalSince(start) / 60
        } else {
            period?.varint(1) == 1 ? 43_200 : 10_080
        }

        return CodexUsageWindow(usedPercent: max(0, percent), windowMinutes: windowMinutes, resetsAt: end)
    }

    private static func timestamp(_ reader: ProtobufReader) -> Date? {
        guard let seconds = reader.varint(1) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Copies grok.com's sign-in from Zen or Firefox, so there's usually no need to sign in again.
    private func seedBrowserCookies() async {
        let cookies = await Task.detached { FirefoxCookies.grokSession() }.value
        let store = dataStore.httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
    }
}

extension GrokWebSession: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        verifyTimer?.invalidate()
        verifyTimer = nil
        verifyWindow = nil
    }
}

/// An off-screen web view for one check.
@MainActor
private final class HiddenPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var continuation: CheckedContinuation<Void, Error>?

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 20))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                self?.finish(GrokWebError.timedOut)
            }
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// Just enough protobuf to read a few known fields.
private nonisolated struct ProtobufReader {
    private var fields: [Int: [Any]] = [:]

    init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        let bytes = Array(bytes)
        var index = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }

        while index < bytes.count, let key = readVarint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = readVarint() else { return }
                fields[field, default: []].append(value)
            case 1:
                guard index + 8 <= bytes.count else { return }
                index += 8
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return }
                fields[field, default: []].append(Array(bytes[index..<(index + Int(length))]))
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return }
                let raw = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
                fields[field, default: []].append(Float(bitPattern: raw))
                index += 4
            default:
                return
            }
        }
    }

    func varint(_ field: Int) -> UInt64? { fields[field]?.first as? UInt64 }
    func float(_ field: Int) -> Float? { fields[field]?.first as? Float }
    func message(_ field: Int) -> [UInt8]? { fields[field]?.first as? [UInt8] }
}

/// Reads grok.com's `sso` cookies from Firefox-based browsers, whose cookie store isn't encrypted.
private nonisolated enum FirefoxCookies {
    static func grokSession() -> [HTTPCookie] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let profileRoots = ["zen/Profiles", "Firefox/Profiles"].map { support.appendingPathComponent($0) }

        var best: (lastAccessed: Int64, cookies: [HTTPCookie]) = (0, [])
        for root in profileRoots {
            let profiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for profile in profiles {
                let database = profile.appendingPathComponent("cookies.sqlite")
                guard FileManager.default.fileExists(atPath: database.path),
                      let found = read(database), found.lastAccessed > best.lastAccessed else { continue }
                best = found
            }
        }
        return best.cookies
    }

    /// Works on a copy, since the browser keeps the database locked and recent writes in its WAL.
    private static func read(_ database: URL) -> (lastAccessed: Int64, cookies: [HTTPCookie])? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ousage-cookies-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }

        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: copy.appendingPathComponent("cookies.sqlite" + suffix))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.appendingPathComponent("cookies.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT name, value, host, path, expiry, lastAccessed FROM moz_cookies
        WHERE host IN ('.grok.com', 'grok.com') AND name IN ('sso', 'sso-rw')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var cookies: [HTTPCookie] = []
        var lastAccessed: Int64 = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let value = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let host = sqlite3_column_text(statement, 2).map({ String(cString: $0) }) else { continue }
            let path = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "/"
            let expiry = sqlite3_column_int64(statement, 4)
            lastAccessed = max(lastAccessed, sqlite3_column_int64(statement, 5))

            // Newer Firefox stores expiry in milliseconds. Session cookies get a month, so they
            // survive between checks.
            let expires: Date = if expiry > 100_000_000_000 {
                Date(timeIntervalSince1970: TimeInterval(expiry) / 1000)
            } else if expiry > 0 {
                Date(timeIntervalSince1970: TimeInterval(expiry))
            } else {
                Date().addingTimeInterval(30 * 24 * 60 * 60)
            }

            if let cookie = HTTPCookie(properties: [
                .name: name, .value: value, .domain: host, .path: path,
                .secure: "TRUE", .expires: expires,
            ]) {
                cookies.append(cookie)
            }
        }
        return cookies.isEmpty ? nil : (lastAccessed, cookies)
    }
}

nonisolated enum GrokWebError: LocalizedError {
    case needsVerification
    case signedOut
    case timedOut
    case serverError(Int)
    case invalidResponse

    /// Opening grok.com in a window fixes these.
    var needsConnection: Bool {
        switch self {
        case .needsVerification, .signedOut: true
        case .timedOut, .serverError, .invalidResponse: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .needsVerification:
            return "grok.com needs a one-time browser check."
        case .signedOut:
            return "Not signed in to grok.com. Connect to sign in."
        case .timedOut:
            return "grok.com didn’t respond in time."
        case .serverError(let status):
            return "grok.com usage request failed (HTTP \(status))."
        case .invalidResponse:
            return "grok.com returned usage in an unexpected format."
        }
    }
}
