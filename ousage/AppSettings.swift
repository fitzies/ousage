//
//  AppSettings.swift
//  ousage
//

import Combine
import Foundation

nonisolated enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case openCode
    case openRouter
    case grok
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .openCode: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }

    var icon: String {
        switch self {
        case .claude: "ClaudeIcon"
        case .codex: "CodexIcon"
        case .openCode: "OpenCodeIcon"
        case .openRouter: "OpenRouterIcon"
        case .grok: "GrokIcon"
        case .cursor: "CursorIcon"
        }
    }
}

nonisolated enum SystemMonitor: String, CaseIterable, Codable, Identifiable, Sendable {
    case network
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: "Network"
        case .disk: "Disk"
        }
    }

    var detail: String {
        switch self {
        case .network: "Speed test download and upload"
        case .disk: "Read and write speed"
        }
    }

    var symbol: String {
        switch self {
        case .network: "network"
        case .disk: "internaldrive"
        }
    }
}

/// Where a menu bar item's value comes from; consecutive items from one source share an icon.
nonisolated enum MenuBarSource: Hashable, Sendable {
    case provider(Provider)
    case system(SystemMonitor)
}

nonisolated enum MenuBarItem: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeFiveHour
    case claudeWeekly
    case claudeFable
    case codexFiveHour
    case codexWeekly
    case codexMonthly
    case openCodeFiveHour
    case openCodeWeekly
    case openCodeMonthly
    case openRouterBalance
    case grokSuperGrok
    /// Raw value predates the SuperGrok items, so saved settings still decode.
    case grokBot = "grokWeekly"
    case cursorTotal
    case cursorAuto
    case cursorAPI
    case networkDownload
    case networkUpload
    case diskRead
    case diskWrite

    var id: String { rawValue }

    var source: MenuBarSource {
        switch self {
        case .claudeFiveHour, .claudeWeekly, .claudeFable: .provider(.claude)
        case .codexFiveHour, .codexWeekly, .codexMonthly: .provider(.codex)
        case .openCodeFiveHour, .openCodeWeekly, .openCodeMonthly: .provider(.openCode)
        case .openRouterBalance: .provider(.openRouter)
        case .grokSuperGrok, .grokBot: .provider(.grok)
        case .cursorTotal, .cursorAuto, .cursorAPI: .provider(.cursor)
        case .networkDownload, .networkUpload: .system(.network)
        case .diskRead, .diskWrite: .system(.disk)
        }
    }

    /// Name used in Settings.
    var title: String {
        switch self {
        case .claudeFiveHour, .codexFiveHour, .openCodeFiveHour: "5h"
        case .claudeWeekly, .codexWeekly, .openCodeWeekly, .grokSuperGrok: "Week"
        case .claudeFable: "Fable"
        case .codexMonthly, .openCodeMonthly: "Month"
        case .openRouterBalance: "Balance"
        case .grokBot: "Grok Bot"
        case .cursorTotal: "Total"
        case .cursorAuto: "Auto"
        case .cursorAPI: "API"
        case .networkDownload: "Download"
        case .networkUpload: "Upload"
        case .diskRead: "Read"
        case .diskWrite: "Write"
        }
    }

    /// Prefix shown before the value in the menu bar.
    var shortLabel: String? {
        switch self {
        case .claudeFiveHour, .codexFiveHour, .openCodeFiveHour: "H"
        case .claudeWeekly, .codexWeekly, .openCodeWeekly, .grokSuperGrok: "W"
        case .claudeFable: "F"
        case .codexMonthly, .openCodeMonthly: "M"
        case .openRouterBalance: nil
        case .grokBot: "B"
        case .cursorTotal: "T"
        case .cursorAuto: "A"
        case .cursorAPI: "API"
        case .networkDownload: "↓"
        case .networkUpload: "↑"
        case .diskRead: "R"
        case .diskWrite: "W"
        }
    }

    static func items(for source: MenuBarSource) -> [MenuBarItem] {
        allCases.filter { $0.source == source }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var enabledProviders: Set<Provider> { didSet { save() } }
    @Published var enabledMonitors: Set<SystemMonitor> { didSet { save() } }
    @Published var menuBarItems: [MenuBarItem] { didSet { save() } }
    @Published var showsMenuBarIcons: Bool { didSet { save() } }
    @Published var colorsMenuBarByPace: Bool { didSet { save() } }
    @Published var speedTestInterval: SpeedTestInterval { didSet { save() } }

    private let defaults: UserDefaults
    private static let key = "settings.v1"

    private struct Stored: Codable {
        var enabledProviders: Set<Provider>
        var enabledMonitors: Set<SystemMonitor>
        var menuBarItems: [MenuBarItem]
        var showsMenuBarIcons: Bool
        var colorsMenuBarByPace: Bool
        /// Optional so settings saved before speed tests existed still decode.
        var speedTestInterval: SpeedTestInterval?
        /// Providers that existed when these settings were saved, so newly added ones can be
        /// turned on once if they're signed in. Missing in settings saved before Cursor existed.
        var knownProviders: Set<Provider>?

        init(
            enabledProviders: Set<Provider>,
            enabledMonitors: Set<SystemMonitor>,
            menuBarItems: [MenuBarItem],
            showsMenuBarIcons: Bool,
            colorsMenuBarByPace: Bool,
            speedTestInterval: SpeedTestInterval?,
            knownProviders: Set<Provider>? = Set(Provider.allCases)
        ) {
            self.enabledProviders = enabledProviders
            self.enabledMonitors = enabledMonitors
            self.menuBarItems = menuBarItems
            self.showsMenuBarIcons = showsMenuBarIcons
            self.colorsMenuBarByPace = colorsMenuBarByPace
            self.speedTestInterval = speedTestInterval
            self.knownProviders = knownProviders
        }

        /// Skips menu bar items that no longer exist (like Grok's old 2h limit) instead of resetting everything.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabledProviders = try container.decode(Set<Provider>.self, forKey: .enabledProviders)
            enabledMonitors = try container.decode(Set<SystemMonitor>.self, forKey: .enabledMonitors)
            menuBarItems = try container.decode([String].self, forKey: .menuBarItems).compactMap(MenuBarItem.init(rawValue:))
            showsMenuBarIcons = try container.decode(Bool.self, forKey: .showsMenuBarIcons)
            colorsMenuBarByPace = try container.decode(Bool.self, forKey: .colorsMenuBarByPace)
            speedTestInterval = try container.decodeIfPresent(SpeedTestInterval.self, forKey: .speedTestInterval)
            knownProviders = try? container.decodeIfPresent([String].self, forKey: .knownProviders)
                .map { Set($0.compactMap(Provider.init(rawValue:))) }
        }
    }

    /// Without saved settings, starts from whatever is signed in on this Mac.
    init(defaults: UserDefaults = .standard, detected: Set<Provider>) {
        self.defaults = defaults

        let stored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            ?? Self.initialSettings(detected: detected)

        // Providers added since these settings were saved start on when they're signed in.
        let known = stored.knownProviders ?? Set(Provider.allCases).subtracting([.cursor])
        enabledProviders = stored.enabledProviders.union(detected.subtracting(known))
        enabledMonitors = stored.enabledMonitors
        menuBarItems = stored.menuBarItems
        showsMenuBarIcons = stored.showsMenuBarIcons
        colorsMenuBarByPace = stored.colorsMenuBarByPace
        speedTestInterval = stored.speedTestInterval ?? .hour
        save()
    }

    private static func initialSettings(detected: Set<Provider>) -> Stored {
        let menuBarItems: [MenuBarItem] = if detected.contains(.claude) {
            [.claudeFiveHour, .claudeWeekly]
        } else if detected.contains(.codex) {
            [.codexFiveHour, .codexWeekly]
        } else {
            [.networkDownload, .networkUpload]
        }

        return Stored(
            enabledProviders: detected,
            enabledMonitors: [.network, .disk],
            menuBarItems: menuBarItems,
            showsMenuBarIcons: false,
            colorsMenuBarByPace: true,
            speedTestInterval: .hour
        )
    }

    func isEnabled(_ source: MenuBarSource) -> Bool {
        switch source {
        case .provider(let provider): enabledProviders.contains(provider)
        case .system(let monitor): enabledMonitors.contains(monitor)
        }
    }

    func setEnabled(_ enabled: Bool, for source: MenuBarSource) {
        switch source {
        case .provider(let provider):
            if enabled { enabledProviders.insert(provider) } else { enabledProviders.remove(provider) }
        case .system(let monitor):
            if enabled { enabledMonitors.insert(monitor) } else { enabledMonitors.remove(monitor) }
        }

        if !enabled {
            menuBarItems.removeAll { $0.source == source }
        }
    }

    /// Items to draw, skipping any whose source has since been turned off.
    var visibleMenuBarItems: [MenuBarItem] {
        menuBarItems.filter { isEnabled($0.source) }
    }

    func toggleMenuBarItem(_ item: MenuBarItem) {
        if let index = menuBarItems.firstIndex(of: item) {
            menuBarItems.remove(at: index)
        } else {
            menuBarItems.append(item)
        }
    }

    /// Places `item` where `target` is, shifting the rest along.
    func moveMenuBarItem(_ item: MenuBarItem, to target: MenuBarItem) {
        guard item != target,
              let from = menuBarItems.firstIndex(of: item),
              let to = menuBarItems.firstIndex(of: target) else { return }
        var items = menuBarItems
        items.remove(at: from)
        items.insert(item, at: to)
        menuBarItems = items
    }

    private func save() {
        let stored = Stored(
            enabledProviders: enabledProviders,
            enabledMonitors: enabledMonitors,
            menuBarItems: menuBarItems,
            showsMenuBarIcons: showsMenuBarIcons,
            colorsMenuBarByPace: colorsMenuBarByPace,
            speedTestInterval: speedTestInterval
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Looks for each tool's sign-in on this Mac without reading any secrets.
nonisolated enum ProviderDetection {
    static func isSignedIn(_ provider: Provider) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude:
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
        case .codex:
            guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["tokens"] != nil
        case .cursor:
            return CursorAuth.exists()
        case .grok:
            if GrokCLIAuth.exists { return true }
            guard let data = try? Data(contentsOf: GrokBotFiles.secrets),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["cursor-accounts"] != nil
        case .openCode, .openRouter:
            return false
        }
    }
}
