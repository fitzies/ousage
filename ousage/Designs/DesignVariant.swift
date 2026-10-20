//
//  DesignVariant.swift
//  ousage
//
//  Design exploration: a switchable set of popover layouts that all read the same live stores.
//  The compact list lives in ConceptB_List.swift; this file holds the shared model and helpers.
//

import AppKit
import SwiftUI

// MARK: - Variant

/// Which popover layout to show. Stored in UserDefaults so it survives relaunches.
enum DesignVariant: String, CaseIterable, Identifiable {
    case classic
    case list

    static let storageKey = "designVariant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Current (classic)"
        case .list: "Compact list"
        }
    }

    var detail: String {
        switch self {
        case .classic: "Tiles per window, as today."
        case .list: "Dense sectioned list in the openusage mould."
        }
    }

    /// The width each layout is designed for.
    var width: CGFloat {
        switch self {
        case .classic: 340
        case .list: 300
        }
    }
}

// MARK: - Shared model

/// Everything a popover design needs, flattened out of the individual stores.
/// Designs render this; `live(...)` builds it from the real stores and `sample` builds it for previews.
struct PopoverModel {
    struct Metric: Identifiable {
        enum Kind {
            /// A rate-limit window; `nil` means the provider has it but it isn't available right now.
            case usage(CodexUsageWindow?)
            /// A free-form value such as a balance or a speed; `nil` while unmeasured.
            case value(String?)
        }

        let id: String
        let label: String
        let kind: Kind

        var window: CodexUsageWindow? {
            if case .usage(let window) = kind { return window }
            return nil
        }

        var text: String? {
            if case .value(let value) = kind { return value }
            return nil
        }

        var isUsage: Bool {
            if case .usage = kind { return true }
            return false
        }

        static func usage(_ label: String, _ window: CodexUsageWindow?) -> Metric {
            Metric(id: label, label: label, kind: .usage(window))
        }

        static func value(_ label: String, _ value: String?) -> Metric {
            Metric(id: label, label: label, kind: .value(value))
        }
    }

    struct Action {
        let title: String
        let handler: () -> Void
    }

    struct Panel: Identifiable {
        enum Source {
            case provider(Provider)
            case monitor(SystemMonitor)
        }

        let source: Source
        var subtitle: String? = nil
        var fetchedAt: Date? = nil
        var isLoading = false
        var metrics: [Metric] = []
        /// Shown instead of metrics while there's nothing to show yet.
        var placeholder: String? = nil
        /// Warnings from the store, e.g. sign-in problems.
        var notes: [String] = []
        var action: Action? = nil

        var id: String {
            switch source {
            case .provider(let provider): provider.rawValue
            case .monitor(let monitor): "monitor.\(monitor.rawValue)"
            }
        }

        var title: String {
            switch source {
            case .provider(let provider): provider.title
            case .monitor(let monitor): monitor.title
            }
        }

        var asset: String? {
            if case .provider(let provider) = source { return provider.icon }
            return nil
        }

        var symbol: String? {
            if case .monitor(let monitor) = source { return monitor.symbol }
            return nil
        }

        /// Brand-ish accent, kept muted so the pace colours still stand out.
        var tint: Color {
            switch source {
            case .provider(.claude): Color(red: 0.85, green: 0.47, blue: 0.34)
            case .provider(.codex): Color(red: 0.06, green: 0.64, blue: 0.52)
            case .provider(.grok): Color(red: 0.42, green: 0.40, blue: 0.80)
            case .provider(.openCode): Color(red: 0.25, green: 0.56, blue: 0.95)
            case .provider(.openRouter): Color(red: 0.55, green: 0.38, blue: 0.85)
            case .monitor(.network): Color(red: 0.20, green: 0.66, blue: 0.86)
            case .monitor(.disk): Color(white: 0.55)
            case .provider(.cursor): Color(white: 0.35)
            // Providers added later fall back to a neutral tint until given one.
            default: Color(white: 0.45)
            }
        }

        var usageMetrics: [Metric] { metrics.filter(\.isUsage) }

        /// The window that's furthest ahead of an even pace, or the fullest one if pace is unknown.
        var tightestWindow: (label: String, window: CodexUsageWindow)? {
            let windows = metrics.compactMap { metric in metric.window.map { (metric.label, $0) } }
            return windows.max { lhs, rhs in Self.urgency(lhs.1) < Self.urgency(rhs.1) }
        }

        static func urgency(_ window: CodexUsageWindow) -> Double {
            let overPace = window.paceAllowancePercent.map { window.clampedPercent - $0 } ?? 0
            return overPace * 2 + window.clampedPercent
        }
    }

    var providers: [Panel]
    var monitors: [Panel]
    var isRefreshing: Bool
    var refresh: () -> Void
    var openSettings: () -> Void

    var isEmpty: Bool { providers.isEmpty && monitors.isEmpty }

    var panels: [Panel] { providers + monitors }

    /// The most recent fetch across providers, for footers.
    var latestFetch: Date? {
        providers.compactMap(\.fetchedAt).max()
    }

    /// The single window worth a hero treatment.
    var hero: (panel: Panel, label: String, window: CodexUsageWindow)? {
        providers
            .compactMap { panel in panel.tightestWindow.map { (panel, $0.label, $0.window) } }
            .max { Panel.urgency($0.2) < Panel.urgency($1.2) }
    }
}

// MARK: - Live data

extension PopoverModel {
    static func live(
        settings: AppSettings,
        claude: ClaudeUsageStore,
        codex: CodexUsageStore,
        grok: GrokUsageStore,
        openCode: OpenCodeUsageStore,
        openRouter: OpenRouterBalanceStore,
        cursor: CursorUsageStore? = nil,
        disk: DiskSpeedMonitor,
        speedTest: NetworkSpeedTest,
        openSettings: @escaping () -> Void
    ) -> PopoverModel {
        var providers: [Panel] = []

        if settings.enabledProviders.contains(.claude) {
            var panel = Panel(source: .provider(.claude), subtitle: claude.plan, fetchedAt: claude.snapshot?.fetchedAt)
            panel.isLoading = claude.isRefreshing && claude.snapshot == nil
            if let snapshot = claude.snapshot {
                panel.metrics = [
                    snapshot.fiveHour.map { .usage("5h", $0) },
                    snapshot.weekly.map { .usage("Week", $0) },
                    .usage("Fable", snapshot.fable),
                ].compactMap { $0 }
            } else if claude.message == nil {
                panel.placeholder = "Checking Claude usage…"
            }
            panel.notes = [claude.message].compactMap { $0 }
            providers.append(panel)
        }

        if settings.enabledProviders.contains(.codex) {
            var panel = Panel(source: .provider(.codex), subtitle: codex.plan, fetchedAt: codex.snapshot?.fetchedAt)
            panel.isLoading = codex.isRefreshing && codex.snapshot == nil
            if let snapshot = codex.snapshot {
                panel.metrics = [
                    snapshot.fiveHour.map { .usage("5h", $0) },
                    snapshot.weekly.map { .usage("Week", $0) },
                    snapshot.monthly.map { .usage("Month", $0) },
                ].compactMap { $0 }
            } else if codex.message == nil {
                panel.placeholder = "Checking Codex usage…"
            } else {
                // No usage available (e.g. no active subscription): blanks rather than an error, as the classic view does.
                panel.metrics = [.usage("5h", nil), .usage("Week", nil)]
            }
            providers.append(panel)
        }

        if settings.enabledProviders.contains(.grok) {
            var panel = Panel(source: .provider(.grok), subtitle: grok.plan, fetchedAt: grok.snapshot?.fetchedAt)
            panel.isLoading = grok.isRefreshing && grok.snapshot == nil
            if let snapshot = grok.snapshot {
                panel.metrics = [
                    snapshot.superGrok.map { .usage("Week", $0) },
                    .usage("Grok Bot", snapshot.grokBot),
                ].compactMap { $0 }
            } else if grok.message == nil && grok.webMessage == nil {
                panel.placeholder = "Checking Grok usage…"
            }
            panel.notes = [grok.message, grok.webMessage].compactMap { $0 }
            if grok.needsWebConnection {
                panel.action = Action(title: "Connect grok.com", handler: grok.connectGrokCom)
            }
            providers.append(panel)
        }

        if let cursor, settings.enabledProviders.contains(.cursor) {
            var panel = Panel(source: .provider(.cursor), subtitle: cursor.plan, fetchedAt: cursor.snapshot?.fetchedAt)
            panel.isLoading = cursor.isRefreshing && cursor.snapshot == nil
            if let snapshot = cursor.snapshot {
                panel.metrics = [
                    snapshot.total.map { .usage("Total", $0) },
                    snapshot.auto.map { .usage("Auto", $0) },
                    snapshot.api.map { .usage("API", $0) },
                    snapshot.formattedOnDemand.map { .value("On demand", $0) },
                ].compactMap { $0 }
            } else if cursor.message == nil {
                panel.placeholder = "Checking Cursor usage…"
            }
            panel.notes = [cursor.message].compactMap { $0 }
            providers.append(panel)
        }

        if settings.enabledProviders.contains(.openCode) {
            var panel = Panel(source: .provider(.openCode))
            if openCode.isConfigured {
                panel.fetchedAt = openCode.snapshot?.fetchedAt
                panel.isLoading = openCode.isRefreshing && openCode.snapshot == nil
                if let snapshot = openCode.snapshot {
                    panel.metrics = [
                        snapshot.rolling.map { .usage("5h", $0.usageWindow) },
                        snapshot.weekly.map { .usage("Week", $0.usageWindow) },
                        snapshot.monthly.map { .usage("Month", $0.usageWindow) },
                    ].compactMap { $0 }
                } else {
                    panel.placeholder = openCode.isRefreshing ? "Checking OpenCode usage…" : "Waiting for OpenCode"
                }
            } else {
                panel.placeholder = "Needs an OpenCode API key"
                panel.action = Action(title: "Add key…", handler: openSettings)
            }
            panel.notes = [openCode.message].compactMap { $0 }
            providers.append(panel)
        }

        if settings.enabledProviders.contains(.openRouter) {
            var panel = Panel(source: .provider(.openRouter))
            if openRouter.isConfigured {
                panel.fetchedAt = openRouter.snapshot?.fetchedAt
                panel.isLoading = openRouter.isRefreshing && openRouter.snapshot == nil
                panel.metrics = [.value("Balance", openRouter.snapshot?.formattedBalance)]
            } else {
                panel.placeholder = "Needs an OpenRouter management key"
                panel.action = Action(title: "Add key…", handler: openSettings)
            }
            panel.notes = [openRouter.message].compactMap { $0 }
            providers.append(panel)
        }

        var monitors: [Panel] = []

        if settings.enabledMonitors.contains(.network) {
            var panel = Panel(source: .monitor(.network), fetchedAt: speedTest.result?.testedAt)
            panel.isLoading = speedTest.isRunning && speedTest.result == nil
            panel.metrics = [
                .value("Download", speedTest.result.map { SpeedSample.formatBits($0.download) }),
                .value("Upload", speedTest.result.map { SpeedSample.formatBits($0.upload) }),
            ]
            panel.notes = [speedTest.message].compactMap { $0 }
            monitors.append(panel)
        }

        if settings.enabledMonitors.contains(.disk) {
            var panel = Panel(source: .monitor(.disk))
            panel.metrics = [
                .value("Read", disk.disk.map { SpeedSample.formatBytes($0.inbound) }),
                .value("Write", disk.disk.map { SpeedSample.formatBytes($0.outbound) }),
            ]
            monitors.append(panel)
        }

        return PopoverModel(
            providers: providers,
            monitors: monitors,
            isRefreshing: codex.isRefreshing || grok.isRefreshing || openCode.isRefreshing || openRouter.isRefreshing,
            refresh: {
                if settings.enabledProviders.contains(.claude) { claude.refreshNow() }
                if settings.enabledProviders.contains(.codex) { codex.refreshNow() }
                if settings.enabledProviders.contains(.grok) { grok.refreshNow() }
                if settings.enabledProviders.contains(.openCode) { openCode.refreshNow() }
                if settings.enabledProviders.contains(.openRouter) { openRouter.refreshNow() }
            },
            openSettings: openSettings
        )
    }
}

// MARK: - Sample data

extension PopoverModel {
    /// Plausible numbers for previews and screenshots. Resets are relative to now so pace colours resolve.
    static func sample(now: Date = Date()) -> PopoverModel {
        func window(_ percent: Double, minutes: Double, resetsIn: TimeInterval) -> CodexUsageWindow {
            CodexUsageWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetsIn))
        }
        let hour: TimeInterval = 3600
        let day = 24 * hour

        var claude = Panel(source: .provider(.claude), subtitle: "Max 5x", fetchedAt: now.addingTimeInterval(-90))
        claude.metrics = [
            .usage("5h", window(64, minutes: 300, resetsIn: 1 * hour + 50 * 60)),
            .usage("Week", window(41, minutes: 10_080, resetsIn: 3 * day + 4 * hour)),
            .usage("Fable", window(27, minutes: 10_080, resetsIn: 3 * day + 4 * hour)),
        ]

        var codex = Panel(source: .provider(.codex), subtitle: "Plus", fetchedAt: now.addingTimeInterval(-6 * 60))
        codex.metrics = [
            .usage("5h", window(12, minutes: 300, resetsIn: 4 * hour + 12 * 60)),
            .usage("Week", window(78, minutes: 10_080, resetsIn: 1 * day + 6 * hour)),
            .usage("Month", window(33, minutes: 43_200, resetsIn: 12 * day)),
        ]

        var grok = Panel(source: .provider(.grok), subtitle: "SuperGrok", fetchedAt: now.addingTimeInterval(-3 * 60))
        grok.metrics = [
            .usage("Week", window(58, minutes: 10_080, resetsIn: 2 * day + 20 * hour)),
            .usage("Grok Bot", window(91, minutes: 10_080, resetsIn: 2 * day + 20 * hour)),
        ]

        var openCode = Panel(source: .provider(.openCode), fetchedAt: now.addingTimeInterval(-40))
        openCode.metrics = [
            .usage("5h", window(5, minutes: 300, resetsIn: 3 * hour + 2 * 60)),
            .usage("Week", window(22, minutes: 10_080, resetsIn: 5 * day + 1 * hour)),
            .usage("Month", window(48, minutes: 0, resetsIn: 17 * day)),
        ]

        var openRouter = Panel(source: .provider(.openRouter), fetchedAt: now.addingTimeInterval(-12 * 60))
        openRouter.metrics = [.value("Balance", "$42.18")]

        var network = Panel(source: .monitor(.network), fetchedAt: now.addingTimeInterval(-25 * 60))
        network.metrics = [.value("Download", "912 Mbps"), .value("Upload", "38 Mbps")]

        var disk = Panel(source: .monitor(.disk))
        disk.metrics = [.value("Read", "1.2 GB/s"), .value("Write", "118 MB/s")]

        return PopoverModel(
            providers: [claude, codex, grok, openCode, openRouter],
            monitors: [network, disk],
            isRefreshing: false,
            refresh: {},
            openSettings: {}
        )
    }
}

// MARK: - Root switch

/// Picks the concept for the stored variant. `.classic` is handled by `ContentView` itself.
struct DesignVariantView: View {
    let variant: DesignVariant
    let model: PopoverModel

    var body: some View {
        Group {
            switch variant {
            case .classic, .list: ListDesign(model: model)
            }
        }
        .frame(width: variant.width)
        .contentShape(Rectangle())
        .contextMenu { DesignMenuItems(openSettings: model.openSettings) }
    }
}

struct DesignMenuItems: View {
    let openSettings: () -> Void

    var body: some View {
        Button("Settings…", action: openSettings)
        Button("Quit ousage") {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Shared helpers

extension UsagePace {
    var designColor: Color {
        switch self {
        case .onPace: .green
        case .nearPace: .yellow
        case .aheadOfPace: .red
        case .neutral: .secondary
        }
    }

    var designLabel: String {
        switch self {
        case .onPace: "On pace"
        case .nearPace: "Near pace"
        case .aheadOfPace: "Ahead of pace"
        case .neutral: ""
        }
    }
}

extension CodexUsageWindow {
    /// Compact time until reset, e.g. "4h 38m" or "2d 10h".
    var designShortReset: String? {
        guard let resetsAt else { return nil }

        let remainingMinutes = max(0, Int(ceil(resetsAt.timeIntervalSinceNow / 60)))
        let days = remainingMinutes / (24 * 60)
        let hours = (remainingMinutes % (24 * 60)) / 60
        let minutes = remainingMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// How far used% sits from the even-pace line, e.g. "+12% over pace" or "on pace".
    var designPaceDelta: String? {
        guard let allowance = paceAllowancePercent else { return nil }
        let delta = Int((clampedPercent - allowance).rounded())
        if delta > 2 { return "\(delta)% over pace" }
        if delta < -2 { return "\(-delta)% under pace" }
        return "on pace"
    }

    var designRemaining: String {
        "\(Int((100 - clampedPercent).rounded()))% left"
    }
}

/// Relative time text for "updated …" footers.
func designRelative(_ date: Date?) -> String? {
    guard let date else { return nil }
    if Date().timeIntervalSince(date) < 60 { return "just now" }
    return date.formatted(.relative(presentation: .named))
}

/// Provider logo or monitor symbol, tinted with the current foreground style.
struct DesignGlyph: View {
    let panel: PopoverModel.Panel
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let asset = panel.asset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else if let symbol = panel.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.85, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(panel.title)
    }
}

/// Logo on a coloured continuous-corner tile, like a Settings sidebar icon.
struct DesignIconTile: View {
    let panel: PopoverModel.Panel
    var size: CGFloat = 24

    var body: some View {
        DesignGlyph(panel: panel, size: size * 0.58)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(panel.tint.gradient)
            )
    }
}

/// Thin usage bar with a tick at the even-pace position.
struct DesignBar: View {
    let window: CodexUsageWindow?
    var height: CGFloat = 5
    var color: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))

                if let window {
                    Capsule()
                        .fill(color ?? window.pace.designColor)
                        .frame(width: max(window.clampedPercent > 0 ? height : 0, width * window.clampedPercent / 100))

                    if let pace = window.paceAllowancePercent {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 2, height: height + 4)
                            .offset(x: min(width - 2, width * pace / 100))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Small toolbar buttons shared by the concepts.
struct DesignToolbarButtons: View {
    let model: PopoverModel

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.refresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .disabled(model.isRefreshing)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")

            Button(action: model.openSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Warnings plus an optional action, in the small type the concepts share.
struct DesignNotes: View {
    let panel: PopoverModel.Panel

    var body: some View {
        if !panel.notes.isEmpty || panel.action != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(panel.notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = panel.action {
                    Button(action.title, action: action.handler)
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }
}
