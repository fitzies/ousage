//
//  ContentView.swift
//  ousage
//
//  Created by Oli Fitzgerald on 23/8/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ClaudeUsageStore
    @ObservedObject var codexStore: CodexUsageStore
    @ObservedObject var openCodeStore: OpenCodeUsageStore
    @ObservedObject var openRouterStore: OpenRouterBalanceStore
    @ObservedObject var grokStore: GrokUsageStore
    @ObservedObject var cursorStore: CursorUsageStore
    @ObservedObject var diskMonitor: DiskSpeedMonitor
    @ObservedObject var speedTest: NetworkSpeedTest
    let openSettings: () -> Void

    /// Design exploration: which popover layout to show (see Designs/DesignVariant.swift).
    @AppStorage(DesignVariant.storageKey) private var designVariant = DesignVariant.list

    var body: some View {
        if designVariant == .classic {
            classicBody
        } else {
            DesignVariantView(variant: designVariant, model: designModel)
        }
    }

    private var designModel: PopoverModel {
        .live(
            settings: settings,
            claude: store,
            codex: codexStore,
            grok: grokStore,
            openCode: openCodeStore,
            openRouter: openRouterStore,
            cursor: cursorStore,
            disk: diskMonitor,
            speedTest: speedTest,
            openSettings: openSettings
        )
    }

    private var classicBody: some View {
        VStack(spacing: 16) {
            if settings.enabledProviders.contains(.claude) {
                ClaudeUsageSection(store: store)
            }
            if settings.enabledProviders.contains(.codex) {
                CodexUsageSection(store: codexStore)
            }
            if settings.enabledProviders.contains(.grok) {
                GrokUsageSection(store: grokStore)
            }
            if settings.enabledProviders.contains(.cursor) {
                CursorUsageSection(store: cursorStore)
            }
            if settings.enabledProviders.contains(.openCode) {
                OpenCodeUsageSection(store: openCodeStore)
            }
            if settings.enabledProviders.contains(.openRouter) {
                OpenRouterBalanceSection(store: openRouterStore)
            }
            if settings.enabledMonitors.contains(.network) {
                NetworkSection(speedTest: speedTest)
            }
            if settings.enabledMonitors.contains(.disk) {
                DiskSection(sample: diskMonitor.disk)
            }
            if settings.enabledProviders.isEmpty && settings.enabledMonitors.isEmpty {
                PlaceholderText("Nothing to show. Turn on providers in Settings.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .padding(14)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(codexStore.isRefreshing || grokStore.isRefreshing || cursorStore.isRefreshing || openCodeStore.isRefreshing || openRouterStore.isRefreshing)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(14)
        }
        .contentShape(Rectangle())
        .contextMenu {
            AppMenuItems()
        }
        .environment(\.showSettings, openSettings)
        .frame(width: 340)

    }

    private func refresh() {
        if settings.enabledProviders.contains(.claude) { store.refreshNow() }
        if settings.enabledProviders.contains(.codex) { codexStore.refreshNow() }
        if settings.enabledProviders.contains(.grok) { grokStore.refreshNow() }
        if settings.enabledProviders.contains(.cursor) { cursorStore.refreshNow() }
        if settings.enabledProviders.contains(.openCode) { openCodeStore.refreshNow() }
        if settings.enabledProviders.contains(.openRouter) { openRouterStore.refreshNow() }
    }
}

// MARK: - Sections

private struct ClaudeUsageSection: View {
    @ObservedObject var store: ClaudeUsageStore

    var body: some View {
        ProviderSection(
            title: "Claude",
            icon: "ClaudeIcon",
            fetchedAt: store.snapshot?.fetchedAt,
            isLoading: false
        ) {
            if let snapshot = store.snapshot {
                MetricRow(metrics: [
                    snapshot.fiveHour.map { ("5h", $0) },
                    snapshot.weekly.map { ("Week", $0) },
                ])

                if let fable = snapshot.fable {
                    UsageTile(label: "Fable", window: fable)
                } else {
                    UnavailableUsageTile(label: "Fable")
                }
            } else if store.message == nil {
                PlaceholderText("Checking Claude usage…")
            }

            WarningText(store.message)
        }
    }
}

private struct CodexUsageSection: View {
    @ObservedObject var store: CodexUsageStore

    var body: some View {
        ProviderSection(
            title: "Codex",
            icon: "CodexIcon",
            fetchedAt: store.snapshot?.fetchedAt,
            isLoading: store.isRefreshing && store.snapshot == nil
        ) {
            if let snapshot = store.snapshot {
                MetricRow(metrics: [
                    snapshot.fiveHour.map { ("5h", $0) },
                    snapshot.weekly.map { ("Week", $0) },
                    snapshot.monthly.map { ("Month", $0) },
                ])
            } else if store.message == nil {
                PlaceholderText("Checking Codex usage…")
            } else {
                // No usage available (e.g. no active subscription) — show blanks instead of an error.
                HStack(spacing: 8) {
                    UnavailableUsageTile(label: "5h")
                    UnavailableUsageTile(label: "Week")
                }
            }
        }
    }
}

private struct CursorUsageSection: View {
    @ObservedObject var store: CursorUsageStore

    var body: some View {
        ProviderSection(
            title: "Cursor",
            icon: "CursorIcon",
            fetchedAt: store.snapshot?.fetchedAt,
            isLoading: store.isRefreshing && store.snapshot == nil
        ) {
            if let snapshot = store.snapshot {
                MetricRow(metrics: [
                    snapshot.total.map { ("Total", $0) },
                    snapshot.auto.map { ("Auto", $0) },
                    snapshot.api.map { ("API", $0) },
                ])

                if let onDemand = snapshot.formattedOnDemand {
                    PlaceholderText("On-demand \(onDemand)")
                }
            } else if store.message == nil {
                PlaceholderText("Checking Cursor usage…")
            }

            WarningText(store.message)
        }
    }
}

private struct GrokUsageSection: View {
    @ObservedObject var store: GrokUsageStore

    var body: some View {
        ProviderSection(
            title: "Grok",
            icon: "GrokIcon",
            fetchedAt: store.snapshot?.fetchedAt,
            isLoading: store.isRefreshing && store.snapshot == nil
        ) {
            if let snapshot = store.snapshot {
                HStack(spacing: 8) {
                    if let superGrok = snapshot.superGrok {
                        UsageTile(label: "Week", window: superGrok)
                    }

                    if let grokBot = snapshot.grokBot {
                        UsageTile(label: "Grok Bot", window: grokBot)
                    } else {
                        UnavailableUsageTile(label: "Grok Bot")
                    }
                }
            } else if store.message == nil && store.webMessage == nil {
                PlaceholderText("Checking Grok usage…")
            }

            WarningText(store.message)
            if let webMessage = store.webMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    WarningText(webMessage)
                    if store.needsWebConnection {
                        Button("Connect grok.com", action: store.connectGrokCom)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }
}

private struct OpenCodeUsageSection: View {
    @ObservedObject var store: OpenCodeUsageStore
    @State private var apiKey = ""
    @State private var isEditingKey = false

    var body: some View {
        ProviderSection(
            title: "OpenCode Go",
            icon: "OpenCodeIcon",
            fetchedAt: showsUsage ? store.snapshot?.fetchedAt : nil,
            isLoading: store.isRefreshing && store.snapshot == nil && !isEditingKey,
            onChangeKey: { isEditingKey = true }
        ) {
            if showsUsage {
                if let snapshot = store.snapshot {
                    MetricRow(metrics: [
                        snapshot.rolling.map { ("5h", $0.usageWindow) },
                        snapshot.weekly.map { ("Week", $0.usageWindow) },
                        snapshot.monthly.map { ("Month", $0.usageWindow) },
                    ])
                } else {
                    PlaceholderText(store.isRefreshing ? "Checking OpenCode usage…" : "Waiting for OpenCode")
                }
            } else {
                APIKeyForm(
                    prompt: "Enter an OpenCode API key to show your OpenCode Go usage limits.",
                    placeholder: "OpenCode API key",
                    linkTitle: "Manage keys",
                    linkURL: URL(string: "https://opencode.ai/auth")!,
                    apiKey: $apiKey,
                    isBusy: store.isRefreshing,
                    secondaryAction: secondaryAction,
                    onSave: saveKey
                )
            }

            WarningText(store.message)
        }
    }

    private var showsUsage: Bool {
        store.isConfigured && !isEditingKey
    }

    private var secondaryAction: (title: String, action: () -> Void)? {
        switch store.keySource {
        case .keychain:
            return ("Remove", {
                store.removeAPIKey()
                apiKey = ""
                isEditingKey = false
            })
        case .authFile:
            return ("Cancel", {
                apiKey = ""
                isEditingKey = false
            })
        case nil:
            return nil
        }
    }

    private func saveKey() {
        store.saveAPIKey(apiKey)
        apiKey = ""
        isEditingKey = false
    }
}

private struct OpenRouterBalanceSection: View {
    @ObservedObject var store: OpenRouterBalanceStore
    @State private var apiKey = ""
    @State private var isEditingKey = false

    var body: some View {
        ProviderSection(
            title: "OpenRouter",
            icon: "OpenRouterIcon",
            fetchedAt: showsBalance ? store.snapshot?.fetchedAt : nil,
            isLoading: store.isRefreshing && store.snapshot == nil && !isEditingKey,
            onChangeKey: { isEditingKey = true }
        ) {
            if showsBalance {
                MetricTile(label: "Balance") {
                    Text(store.snapshot?.formattedBalance ?? "—")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                } footer: {
                    EmptyView()
                }
            } else {
                APIKeyForm(
                    prompt: "Enter an OpenRouter management API key to show your USD credit balance.",
                    placeholder: "OpenRouter management API key",
                    linkTitle: "Create management key",
                    linkURL: URL(string: "https://openrouter.ai/settings/management-keys")!,
                    apiKey: $apiKey,
                    isBusy: store.isRefreshing,
                    secondaryAction: store.isConfigured ? ("Remove", {
                        store.removeAPIKey()
                        apiKey = ""
                        isEditingKey = false
                    }) : nil,
                    onSave: saveKey
                )
            }

            WarningText(store.message)
        }
    }

    private var showsBalance: Bool {
        store.isConfigured && !isEditingKey
    }

    private func saveKey() {
        store.saveAPIKey(apiKey)
        apiKey = ""
        isEditingKey = false
    }
}

private struct NetworkSection: View {
    @ObservedObject var speedTest: NetworkSpeedTest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionIcon(systemName: SystemMonitor.network.symbol, title: SystemMonitor.network.title)

                // Tests run on a schedule; only call out results that have gone stale.
                if let testedAt = speedTest.result?.testedAt, Date().timeIntervalSince(testedAt) > 60 * 60 {
                    Text(testedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Tested \(testedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            HStack(spacing: 8) {
                SpeedTile(label: "Download", value: speedTest.result.map { SpeedSample.formatBits($0.download) })
                SpeedTile(label: "Upload", value: speedTest.result.map { SpeedSample.formatBits($0.upload) })
            }

            WarningText(speedTest.message)
        }
    }
}

private struct DiskSection: View {
    let sample: SpeedSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionIcon(systemName: SystemMonitor.disk.symbol, title: SystemMonitor.disk.title)

            HStack(spacing: 8) {
                SpeedTile(label: "Read", value: sample.map { SpeedSample.formatBytes($0.inbound) })
                SpeedTile(label: "Write", value: sample.map { SpeedSample.formatBytes($0.outbound) })
            }
        }
    }
}

private struct SpeedTile: View {
    let label: String
    let value: String?

    var body: some View {
        MetricTile(label: label) {
            Text(value ?? "—")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } footer: {
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "Measuring")
    }
}

// MARK: - Building blocks

private struct ProviderSection<Content: View>: View {
    let title: String
    let icon: String
    let fetchedAt: Date?
    let isLoading: Bool
    var onChangeKey: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                SectionIcon(asset: icon, title: title)

                if let fetchedAt, Date().timeIntervalSince(fetchedAt) > 5 * 60 {
                    Text(fetchedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Last updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            content
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let onChangeKey {
                Button("Change \(title) API Key…", action: onChangeKey)
                Divider()
            }
            AppMenuItems()
        }
    }
}

extension EnvironmentValues {
    @Entry var showSettings: () -> Void = {}
}

private struct AppMenuItems: View {
    @Environment(\.showSettings) private var openSettings

    var body: some View {
        Button("Settings…", action: openSettings)
        Button("Quit ousage") {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// A provider logo or SF Symbol at the head of a section.
struct SectionIcon: View {
    var asset: String? = nil
    var systemName: String? = nil
    let title: String

    var body: some View {
        Group {
            if let asset {
                Image(asset)
                    .resizable()
                    .scaledToFit()
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(.primary)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct MetricRow: View {
    let metrics: [(String, CodexUsageWindow)?]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(metrics.compactMap { $0 }.enumerated()), id: \.offset) { _, metric in
                UsageTile(label: metric.0, window: metric.1)
            }
        }
    }
}

struct MetricTile<Value: View, Footer: View>: View {
    let label: String
    @ViewBuilder let value: Value
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)

            value

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct UsageTile: View {
    let label: String
    let window: CodexUsageWindow

    var body: some View {
        MetricTile(label: label) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.formattedPercent)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color(window.pace))

                Spacer(minLength: 4)

                if let pace = window.formattedPaceAllowance {
                    Text(pace)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                UsageBar(window: window)

                Text(window.shortReset ?? "—")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue(helpText)
    }

    private var helpText: String {
        let pace = window.formattedPaceAllowance.map { ", \($0) at an even pace" } ?? ""
        return "\(window.formattedPercent) used\(pace), \(window.resetDescription ?? "reset unknown")"
    }
}

private struct UnavailableUsageTile: View {
    let label: String

    var body: some View {
        MetricTile(label: label) {
            Text("–%")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 4)

                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue("Unavailable")
    }
}

/// Usage fill with a tick marking where an even pace would be right now.
private struct UsageBar: View {
    let window: CodexUsageWindow

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))

                Capsule()
                    .fill(Color(window.pace))
                    .frame(width: max(window.clampedPercent > 0 ? 4 : 0, width * window.clampedPercent / 100))

                if let pace = window.paceAllowancePercent {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: 8)
                        .offset(x: min(width - 1.5, width * pace / 100))
                }
            }
        }
        .frame(height: 4)
    }
}

struct APIKeyForm: View {
    let prompt: String
    let placeholder: String
    let linkTitle: String
    let linkURL: URL
    @Binding var apiKey: String
    let isBusy: Bool
    let secondaryAction: (title: String, action: () -> Void)?
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)

            HStack {
                Link(linkTitle, destination: linkURL)
                    .font(.caption)

                Spacer()

                if let secondaryAction {
                    Button(secondaryAction.title, action: secondaryAction.action)
                        .buttonStyle(.link)
                        .font(.caption)
                }

                Button("Save", action: onSave)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
        }
    }
}

struct PlaceholderText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

struct WarningText: View {
    let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension CodexUsageWindow {
    /// Compact time until reset, e.g. "4h 38m" or "2d 10h".
    var shortReset: String? {
        guard let resetsAt else { return nil }

        let remainingMinutes = max(0, Int(ceil(resetsAt.timeIntervalSinceNow / 60)))
        let days = remainingMinutes / (24 * 60)
        let hours = (remainingMinutes % (24 * 60)) / 60
        let minutes = remainingMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private extension Color {
    init(_ pace: UsagePace) {
        switch pace {
        case .onPace:
            self = .green
        case .nearPace:
            self = .yellow
        case .aheadOfPace:
            self = .red
        case .neutral:
            self = .secondary
        }
    }
}
