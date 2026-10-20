//
//  SettingsView.swift
//  ousage
//

import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

private enum Pane: String, CaseIterable, Identifiable {
    case general = "General"
    case menuBar = "Menu bar"
    case providers = "Providers"
    case system = "System"
    case about = "About"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .providers: "sparkles"
        case .system: "gauge.with.dots.needle.67percent"
        case .about: "info"
        }
    }

    /// Icon tile colour, following the colour palette picked for the popup.
    func color(_ palette: ListPalette) -> Color {
        let tints = palette.settingsTints
        switch self {
        case .general, .about: return .gray
        case .menuBar: return tints.0
        case .providers: return tints.1
        case .system: return tints.2
        }
    }

    /// Sidebar groups: General alone on top, then headed groups.
    static let groups: [(header: String?, panes: [Pane])] = [
        (nil, [.general]),
        ("Settings", [.menuBar, .providers, .system]),
        ("ousage", [.about]),
    ]
}

/// Greys only, a hair warm. Same tones as oagent's settings.
private enum Tone {
    static let background = dynamic(dark: 0.128, light: 0.955)
    static let sidebarTop = dynamic(dark: 0.13, light: 0.93)
    static let sidebarBottom = dynamic(dark: 0.148, light: 0.905)
    static let divider = dynamic(dark: 0.215, light: 0.84)
    static let selection = dynamic(dark: 0.2, light: 0.86)
    static let box = dynamic(dark: 0.172, light: 0.99)
    static let boxStroke = dynamic(dark: 0.24, light: 0.85)
    static let separator = dynamic(dark: 0.25, light: 0.89)
    static let chip = dynamic(dark: 0.235, light: 0.9)
    static let cap = dynamic(dark: 0.138, light: 0.975)
    static let capEdge = dynamic(dark: 0.115, light: 0.8)
    static let capLip = dynamic(dark: 0.185, light: 0.86)
    static let chevronRing = dynamic(dark: 0.29, light: 0.78)

    private static func dynamic(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: v + 0.005, green: v, blue: v - 0.004, alpha: 1)
        })
    }
}

/// Unified-toolbar height: the title row sits on the traffic lights' centre line.
private let titleBarHeight: CGFloat = 52

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @AppStorage(ListPalette.storageKey) private var palette = ListPalette.brand
    @ObservedObject var claudeStore: ClaudeUsageStore
    @ObservedObject var codexStore: CodexUsageStore
    @ObservedObject var openCodeStore: OpenCodeUsageStore
    @ObservedObject var openRouterStore: OpenRouterBalanceStore
    @ObservedObject var grokStore: GrokUsageStore
    @ObservedObject var cursorStore: CursorUsageStore
    @ObservedObject var speedTest: NetworkSpeedTest

    @State private var pane: Pane = {
        #if DEBUG
        // Dev screenshots: `-ousagePane "Menu bar"`.
        if let name = UserDefaults.standard.string(forKey: "ousagePane"), let pane = Pane(rawValue: name) { return pane }
        #endif
        return .general
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(LinearGradient(colors: [Tone.sidebarTop, Tone.sidebarBottom], startPoint: .top, endPoint: .bottom))
            Rectangle().fill(Tone.divider).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    IconTile(symbol: pane.symbol, color: pane.color(palette))
                    Text(pane.rawValue).font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 17)
                .frame(height: titleBarHeight)
                ScrollView {
                    Group {
                        switch pane {
                        case .general:
                            GeneralPane()
                        case .menuBar:
                            MenuBarPane(settings: settings)
                        case .providers:
                            ProvidersPane(
                                settings: settings,
                                claudeStore: claudeStore,
                                codexStore: codexStore,
                                openCodeStore: openCodeStore,
                                openRouterStore: openRouterStore,
                                grokStore: grokStore,
                                cursorStore: cursorStore
                            )
                        case .system:
                            SystemPane(settings: settings, speedTest: speedTest)
                        case .about:
                            AboutPane()
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 16)
                    .padding(.top, 1)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Tone.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .tint(.gray)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Pane.groups, id: \.panes) { group in
                if let header = group.header {
                    Text(header)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 7)
                        .frame(height: 20)
                        .padding(.top, 19)
                        .padding(.bottom, 4)
                }
                ForEach(group.panes) { item in
                    Button { pane = item } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: item.symbol, color: item.color(palette))
                            Text(item.rawValue).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 37)
                        .background {
                            if pane == item {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Tone.selection)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 13)
        .padding(.top, titleBarHeight)
    }
}

/// Coloured rounded-square tile with a white glyph or logo, like System Settings.
private struct IconTile: View {
    var asset: String? = nil
    var symbol: String? = nil
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let asset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
        .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

private extension Provider {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.5)
        case .openCode: Color(white: 0.3)
        case .openRouter: Color(red: 0.39, green: 0.4, blue: 0.95)
        case .grok: Color(white: 0.2)
        case .cursor: Color(white: 0.12)
        }
    }
}

private extension SystemMonitor {
    var color: Color {
        switch self {
        case .network: .blue
        case .disk: .teal
        }
    }
}

private extension MenuBarSource {
    var color: Color {
        switch self {
        case .provider(let provider): provider.color
        case .system(let monitor): monitor.color
        }
    }
}

// MARK: - Grouped boxes

/// A titled group: grey header (optional trailing glyph), a bordered box with full-width separators, footer.
private struct SettingsSection<Content: View, Footer: View>: View {
    var title: String?
    var glyph: String?
    var boxed = true
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if let glyph {
                        Image(systemName: glyph)
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Tone.background)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(.secondary))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.trailing, 9)
            }
            if boxed {
                Group(subviews: content) { rows in
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Rectangle().fill(Tone.separator).frame(height: 1) }
                            row
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Tone.box))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Tone.boxStroke))
            } else {
                content
            }
            footer
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: String? = nil, glyph: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, glyph: glyph, content: content, footer: { EmptyView() })
    }
}

/// One line in a box: label left, control right.
private struct SettingsRow<Label: View, Control: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            control
        }
        .font(.system(size: 13))
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 41)
    }
}

extension SettingsRow where Label == Text {
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.init(label: { Text(label) }, control: control)
    }
}

/// A row label with a coloured logo tile and an optional second line.
private struct RowLabel: View {
    let title: String
    var detail: String? = nil
    var asset: String? = nil
    var symbol: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            IconTile(asset: asset, symbol: symbol, color: color)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

private struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(label) { SettingsSwitch(isOn: $isOn) }
    }
}

/// Pop-up: the value in primary text, then a small ringed ⌃⌄ button.
private struct ValueMenu<V: Hashable>: View {
    @Binding var selection: V
    let options: [(value: V, title: String)]

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 10) {
                Text(options.first { $0.value == selection }?.title ?? "—")
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(Tone.chevronRing, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(DesignVariant.storageKey) private var designVariant = DesignVariant.list
    @AppStorage(ListPalette.storageKey) private var listPalette = ListPalette.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection {
                SettingsToggle(label: "Launch at login", isOn: $launchAtLogin)
            } footer: {
                if let loginError { Text(loginError) }
            }
            .onChange(of: launchAtLogin) { _, isOn in setLogin(isOn) }

            SettingsSection(title: "Popup design", glyph: "paintbrush.fill") {
                SettingsRow("Layout") {
                    ValueMenu(
                        selection: $designVariant,
                        options: DesignVariant.allCases.map { ($0, $0.title) }
                    )
                }
                if designVariant == .list {
                    SettingsRow("Colours") {
                        ValueMenu(
                            selection: $listPalette,
                            options: ListPalette.allCases.map { ($0, $0.title) }
                        )
                    }
                }
            } footer: {
                Text(designVariant == .list ? "\(designVariant.detail) \(listPalette.detail)" : designVariant.detail)
            }

            SettingsSection(title: "Hotkey", glyph: "command", boxed: false) {
                HStack(spacing: 7) {
                    Keycap(symbol: "⇧", name: "")
                    Keycap(symbol: "⌃", name: "ctrl")
                    Keycap(symbol: "⌥", name: "opt")
                    Keycap(symbol: "⌘", name: "cmd")
                    Keycap(symbol: "", name: "U", isKey: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tone.box))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tone.boxStroke))
            } footer: {
                Text("Opens the ousage popup from anywhere.")
            }
        }
    }

    private func setLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Equal-width recessed cap. Modifiers: glyph top-left, name bottom-left; the key itself centred.
private struct Keycap: View {
    let symbol: String
    let name: String
    var isKey = false

    var body: some View {
        Group {
            if isKey {
                Text(name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !name.isEmpty { Text(symbol).font(.system(size: 15)) }
                    Spacer(minLength: 0)
                    Text(name.isEmpty ? symbol : name).font(.system(size: name.isEmpty ? 15 : 13.5))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tone.cap.shadow(.inner(color: .black.opacity(0.4), radius: 1, y: 1)))
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1).padding(1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.capEdge, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.capLip).offset(y: 1.5))
    }
}

// MARK: - Menu bar

private struct MenuBarPane: View {
    @ObservedObject var settings: AppSettings
    @State private var dragging: MenuBarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Shown", glyph: "menubar.rectangle", boxed: false) {
                FlowLayout(spacing: 6) {
                    ForEach(settings.visibleMenuBarItems) { item in
                        MenuBarChip(item: item, isSelected: true, showsSource: true) {
                            withAnimation(.snappy) { settings.toggleMenuBarItem(item) }
                        }
                        .opacity(dragging == item ? 0.4 : 1)
                        .onDrag {
                            dragging = item
                            return NSItemProvider(object: item.rawValue as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ReorderDropDelegate(item: item, settings: settings, dragging: $dragging)
                        )
                    }

                    if settings.visibleMenuBarItems.isEmpty {
                        Text("Only the ousage icon is shown.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 5)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Tone.box))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Tone.boxStroke))
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    dragging = nil
                    return true
                }
            } footer: {
                Text("Drag to reorder, click to remove. Everything stays in the popup either way.")
            }

            SettingsSection(title: "Add", glyph: "plus") {
                ForEach(availableSources, id: \.self) { source in
                    SettingsRow {
                        sourceLabel(source)
                    } control: {
                        HStack(spacing: 5) {
                            ForEach(MenuBarItem.items(for: source)) { item in
                                MenuBarChip(item: item, isSelected: settings.menuBarItems.contains(item), showsSource: false) {
                                    withAnimation(.snappy) { settings.toggleMenuBarItem(item) }
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Turn providers and system stats on in their panes to list them here.")
            }

            SettingsSection("Style") {
                SettingsToggle(label: "Logos before each group", isOn: $settings.showsMenuBarIcons)
                SettingsToggle(label: "Yellow or red when ahead of pace", isOn: $settings.colorsMenuBarByPace)
            }
        }
    }

    private var availableSources: [MenuBarSource] {
        let sources = Provider.allCases.map(MenuBarSource.provider) + SystemMonitor.allCases.map(MenuBarSource.system)
        return sources.filter { settings.isEnabled($0) }
    }

    @ViewBuilder
    private func sourceLabel(_ source: MenuBarSource) -> some View {
        switch source {
        case .provider(let provider):
            RowLabel(title: provider.title, asset: provider.icon, color: provider.color)
        case .system(let monitor):
            RowLabel(title: monitor.title, symbol: monitor.symbol, color: monitor.color)
        }
    }
}

/// Tap toggles. Not a Button, since a button keeps the mouse and drags never start.
private struct MenuBarChip: View {
    let item: MenuBarItem
    let isSelected: Bool
    let showsSource: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if showsSource {
                sourceIcon
                    .frame(width: 11, height: 11)
                    .foregroundStyle(item.source.color)
            }
            Text(item.title)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(isSelected ? Tone.chip : .clear))
        .overlay(Capsule().strokeBorder(isSelected ? .clear : Tone.boxStroke))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .help(isSelected ? "Remove from menu bar" : "Add to menu bar")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(sourceTitle) \(item.title)")
        .accessibilityValue(isSelected ? "In menu bar" : "Not in menu bar")
        .accessibilityAction { action() }
    }

    private var sourceTitle: String {
        switch item.source {
        case .provider(let provider): provider.title
        case .system(let monitor): monitor.title
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch item.source {
        case .provider(let provider):
            Image(provider.icon).renderingMode(.template).resizable().scaledToFit()
        case .system(let monitor):
            Image(systemName: monitor.symbol).font(.system(size: 9, weight: .semibold))
        }
    }
}

/// Moves the dragged chip into place as it passes over others.
private struct ReorderDropDelegate: DropDelegate {
    let item: MenuBarItem
    let settings: AppSettings
    @Binding var dragging: MenuBarItem?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item else { return }
        withAnimation(.snappy) {
            settings.moveMenuBarItem(dragging, to: item)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Lays out children left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Providers

private struct ProvidersPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var claudeStore: ClaudeUsageStore
    @ObservedObject var codexStore: CodexUsageStore
    @ObservedObject var openCodeStore: OpenCodeUsageStore
    @ObservedObject var openRouterStore: OpenRouterBalanceStore
    @ObservedObject var grokStore: GrokUsageStore
    @ObservedObject var cursorStore: CursorUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Subscriptions", glyph: "person.fill") {
                providerToggle(.claude, detail: signInStatus(plan: claudeStore.plan, provider: .claude))
                providerToggle(.codex, detail: signInStatus(plan: codexStore.plan, provider: .codex))
                providerToggle(.grok, detail: signInStatus(plan: grokStore.plan, provider: .grok))
                // grok.com is only the fallback when the Grok CLI isn't signed in.
                if settings.isEnabled(.provider(.grok)) && !grokStore.usesGrokCLI {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("grok.com")
                            Text(grokComStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } control: {
                        Button(grokStore.snapshot?.superGrok == nil ? "Connect…" : "Reconnect…", action: grokStore.connectGrokCom)
                    }
                }
                providerToggle(.cursor, detail: signInStatus(plan: cursorStore.plan, provider: .cursor))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found from the Claude Code, Codex, Grok and Cursor CLIs (or apps) signed in on this Mac — no keys to paste. Without the Grok CLI (`grok login`), SuperGrok limits come from grok.com instead, and Grok Bot’s sign-in is read through the Keychain, so macOS asks once.")
                    if settings.isEnabled(.provider(.grok)) {
                        ForEach([grokStore.message, grokStore.webMessage].compactMap { $0 }, id: \.self) { message in
                            Text(message).foregroundStyle(.orange)
                        }
                    }
                    if settings.isEnabled(.provider(.cursor)), let message = cursorStore.message {
                        Text(message).foregroundStyle(.orange)
                    }
                }
            }

            SettingsSection(title: "OpenCode Go", glyph: "key.fill") {
                providerToggle(.openCode, detail: openCodeStatus)
                KeyRow(
                    isConfigured: openCodeStore.isConfigured,
                    canRemove: openCodeStore.keySource == .keychain,
                    onSave: openCodeStore.saveAPIKey,
                    onRemove: openCodeStore.removeAPIKey
                )
            } footer: {
                KeyFooter(
                    text: "Shows your OpenCode Go usage limits.",
                    linkTitle: "Manage keys",
                    linkURL: URL(string: "https://opencode.ai/auth")!,
                    message: openCodeStore.message
                )
            }

            SettingsSection(title: "OpenRouter", glyph: "key.fill") {
                providerToggle(.openRouter, detail: openRouterStore.isConfigured ? "Key saved" : "No API key")
                KeyRow(
                    isConfigured: openRouterStore.isConfigured,
                    canRemove: openRouterStore.isConfigured,
                    onSave: openRouterStore.saveAPIKey,
                    onRemove: openRouterStore.removeAPIKey
                )
            } footer: {
                KeyFooter(
                    text: "Needs a management key to show your USD credit balance.",
                    linkTitle: "Create management key",
                    linkURL: URL(string: "https://openrouter.ai/settings/management-keys")!,
                    message: openRouterStore.message
                )
            }
        }
    }

    private func providerToggle(_ provider: Provider, detail: String) -> some View {
        SettingsRow {
            RowLabel(title: provider.title, detail: detail, asset: provider.icon, color: provider.color)
        } control: {
            SettingsSwitch(isOn: Binding(
                get: { settings.isEnabled(.provider(provider)) },
                set: { settings.setEnabled($0, for: .provider(provider)) }
            ))
        }
    }

    private var openCodeStatus: String {
        switch openCodeStore.keySource {
        case .authFile: "Key from OpenCode"
        case .keychain: "Key saved"
        case nil: "No API key"
        }
    }

    private var grokComStatus: String {
        if grokStore.snapshot?.superGrok != nil { return "SuperGrok limits connected" }
        return grokStore.needsWebConnection ? "Needs connecting" : "Checking…"
    }

    private func signInStatus(plan: String?, provider: Provider) -> String {
        if let plan { return "\(plan) plan" }
        return ProviderDetection.isSignedIn(provider) ? "Signed in" : "Not signed in"
    }
}

/// The key field, or a saved key with Change / Remove.
private struct KeyRow: View {
    let isConfigured: Bool
    let canRemove: Bool
    let onSave: (String) -> Void
    let onRemove: () -> Void

    @State private var isEditing = false
    @State private var key = ""

    var body: some View {
        SettingsRow("API key") {
            if isConfigured && !isEditing {
                HStack(spacing: 12) {
                    Text("••••••••").foregroundStyle(.secondary)
                    Button("Change") { isEditing = true }
                    if canRemove {
                        Button("Remove", action: onRemove)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    SecureField("API key", text: $key, prompt: Text("Paste key"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .onSubmit(save)
                    if isEditing {
                        Button("Cancel") {
                            key = ""
                            isEditing = false
                        }
                    }
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(key)
        key = ""
        isEditing = false
    }
}

private struct KeyFooter: View {
    let text: String
    let linkTitle: String
    let linkURL: URL
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(text) Stored in the Keychain.")
                Link(linkTitle, destination: linkURL)
            }
            if let message {
                Text(message).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - System

private struct SystemPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var speedTest: NetworkSpeedTest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Network", glyph: "network") {
                monitorToggle(.network)
                if settings.isEnabled(.system(.network)) {
                    SettingsRow("Test every") {
                        ValueMenu(
                            selection: $settings.speedTestInterval,
                            options: SpeedTestInterval.allCases.map { ($0, $0.title) }
                        )
                    }
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Last test")
                            Text(lastTestDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } control: {
                        if speedTest.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Run now", action: speedTest.runNow)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Uses macOS’s built-in speed test against Apple’s servers. Each test moves about 1 GB on a fast connection, so short intervals add up. Skipped on hotspots and in Low Data Mode.")
                    if let message = speedTest.message {
                        Text(message).foregroundStyle(.orange)
                    }
                }
            }

            SettingsSection(title: "Disk", glyph: "internaldrive") {
                monitorToggle(.disk)
            } footer: {
                Text("Measured once a second, only while the menu bar or popup is showing it.")
            }
        }
    }

    private var lastTestDetail: String {
        guard let result = speedTest.result else { return "Not tested yet" }
        let download = SpeedSample.formatBits(result.download)
        let upload = SpeedSample.formatBits(result.upload)
        return "↓ \(download)  ↑ \(upload) · \(result.testedAt.formatted(.relative(presentation: .named)))"
    }

    private func monitorToggle(_ monitor: SystemMonitor) -> some View {
        SettingsRow {
            RowLabel(title: monitor.title, detail: monitor.detail, symbol: monitor.symbol, color: monitor.color)
        } control: {
            SettingsSwitch(isOn: Binding(
                get: { settings.isEnabled(.system(monitor)) },
                set: { settings.setEnabled($0, for: .system(monitor)) }
            ))
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection {
                SettingsRow("Version") { Text(version).foregroundStyle(.secondary) }
            }
            SettingsSection {
                SettingsRow("Quit ousage") { Button("Quit") { NSApp.terminate(nil) } }
            }
        }
    }
}
