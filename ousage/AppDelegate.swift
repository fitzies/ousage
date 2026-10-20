//
//  AppDelegate.swift
//  ousage
//

import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClaudeUsageStore()
    private let codexStore = CodexUsageStore()
    private let openCodeStore = OpenCodeUsageStore()
    private let openRouterStore = OpenRouterBalanceStore()
    private let grokStore = GrokUsageStore()
    private let cursorStore = CursorUsageStore()
    private let diskMonitor = DiskSpeedMonitor()
    private let speedTest = NetworkSpeedTest()
    private lazy var settings = AppSettings(detected: detectedProviders())
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var toggleHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        #if DEBUG
        // Design previews: `-ousageRenderDesigns /output/dir` writes PNGs of each popup layout and quits.
        if let directory = UserDefaults.standard.string(forKey: DesignPreviewRenderer.launchKey) {
            DesignPreviewRenderer.renderAll(to: URL(fileURLWithPath: directory))
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
        configurePopover()
        configureStatusItem()
        registerHotKey()
        observeUsage()
        registerLaunchAtLogin()
        applySettings()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ousageSettings") { showSettings() }
        #endif
    }

    /// Signed-in CLIs and saved keys decide which providers start enabled.
    private func detectedProviders() -> Set<Provider> {
        var detected = Set(Provider.allCases.filter(ProviderDetection.isSignedIn))
        if openCodeStore.isConfigured { detected.insert(.openCode) }
        if openRouterStore.isConfigured { detected.insert(.openRouter) }
        return detected
    }

    /// Polls only what's enabled, and samples speeds only while something shows them.
    private func applySettings() {
        if settings.enabledProviders.contains(.claude) { store.start() }
        if settings.enabledProviders.contains(.grok) { grokStore.start() }
        if settings.enabledProviders.contains(.cursor) { cursorStore.start() }
        // Codex spawns its CLI to poll, so only keep polling while it's in the menu bar.
        if settings.visibleMenuBarItems.contains(where: { $0.source == .provider(.codex) }) { codexStore.start() }
        speedTest.setInterval(
            settings.enabledMonitors.contains(.network) ? settings.speedTestInterval.seconds : nil
        )
        updateDiskSampling()
        updateStatusTitle()
    }

    /// Disk speed is sampled only while the menu bar or open popup shows it.
    private func updateDiskSampling() {
        let inMenuBar = settings.visibleMenuBarItems.contains { $0.source == .system(.disk) }
        diskMonitor.setActive(disk: inMenuBar || (popover.isShown && settings.enabledMonitors.contains(.disk)))
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                settings: settings,
                store: store,
                codexStore: codexStore,
                openCodeStore: openCodeStore,
                openRouterStore: openRouterStore,
                grokStore: grokStore,
                cursorStore: cursorStore,
                diskMonitor: diskMonitor,
                speedTest: speedTest,
                openSettings: { [weak self] in self?.showSettings() }
            )
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "ousage"
        button.setAccessibilityLabel("ousage")
        statusItem = item
        updateStatusTitle()
    }

    /// Hyper+U (⌃⌥⇧⌘U) toggles the popover from anywhere.
    private func registerHotKey() {
        toggleHotKey = GlobalHotKey(
            keyCode: kVK_ANSI_U,
            modifiers: controlKey | optionKey | shiftKey | cmdKey
        ) { [weak self] in
            self?.togglePopover()
        }
        if toggleHotKey == nil {
            NSLog("Could not register the ousage keyboard shortcut")
        }
    }

    private func observeUsage() {
        Publishers.MergeMany(
            store.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            codexStore.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            openCodeStore.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            openRouterStore.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            grokStore.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            cursorStore.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            diskMonitor.objectWillChange.eraseToAnyPublisher(),
            speedTest.$result.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateStatusTitle()
        }
        .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySettings()
            }
            .store(in: &cancellables)

        // Pace allowances move with time, so re-evaluate the title even without new data.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)

        // OpenCode and OpenRouter only poll on their own while they're in the menu bar.
        Timer.publish(every: 5 * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshKeyedProvidersInMenuBar()
            }
            .store(in: &cancellables)

        // Switching to another app (e.g. ⌘-Tab) doesn't involve a click, so close on deactivation too.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.popover.performClose(nil)
            }
            .store(in: &cancellables)
    }

    private func registerLaunchAtLogin() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let service = SMAppService.mainApp
        guard service.status == .notRegistered else { return }

        do {
            try service.register()
        } catch {
            NSLog("Could not register ousage to launch at login: %@", error.localizedDescription)
        }
    }

    private func refreshEnabledIfStale() {
        let enabled = settings.enabledProviders
        if enabled.contains(.claude) { store.refreshIfStale() }
        if enabled.contains(.codex) { codexStore.refreshIfStale() }
        if enabled.contains(.openCode) { openCodeStore.refreshIfStale() }
        if enabled.contains(.openRouter) { openRouterStore.refreshIfStale() }
        if enabled.contains(.grok) { grokStore.refreshIfStale() }
        if enabled.contains(.cursor) { cursorStore.refreshIfStale() }
    }

    private func refreshKeyedProvidersInMenuBar() {
        let sources = Set(settings.visibleMenuBarItems.map(\.source))
        if sources.contains(.provider(.openCode)) { openCodeStore.refreshIfStale() }
        if sources.contains(.provider(.openRouter)) { openRouterStore.refreshIfStale() }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        let segments = settings.visibleMenuBarItems.map(segment(for:))
        if let image = MenuBarRenderer.image(for: segments, showsIcons: settings.showsMenuBarIcons) {
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "ousage")
        }
        button.setAccessibilityValue(segments.map { "\($0.label ?? "") \($0.value)" }.joined(separator: ", "))
    }

    private func segment(for item: MenuBarItem) -> MenuBarSegment {
        switch item {
        case .claudeFiveHour: usage(item, store.snapshot?.fiveHour)
        case .claudeWeekly: usage(item, store.snapshot?.weekly)
        case .claudeFable: usage(item, store.snapshot?.fable)
        case .codexFiveHour: usage(item, codexStore.snapshot?.fiveHour)
        case .codexWeekly: usage(item, codexStore.snapshot?.weekly)
        case .codexMonthly: usage(item, codexStore.snapshot?.monthly)
        case .openCodeFiveHour: usage(item, openCodeStore.snapshot?.rolling?.usageWindow)
        case .openCodeWeekly: usage(item, openCodeStore.snapshot?.weekly?.usageWindow)
        case .openCodeMonthly: usage(item, openCodeStore.snapshot?.monthly?.usageWindow)
        case .openRouterBalance:
            MenuBarSegment(
                source: item.source,
                label: nil,
                value: openRouterStore.snapshot?.formattedBalance ?? "$—",
                color: openRouterStore.snapshot == nil ? .secondaryLabelColor : .labelColor
            )
        case .grokSuperGrok: usage(item, grokStore.snapshot?.superGrok)
        case .grokBot: usage(item, grokStore.snapshot?.grokBot)
        case .cursorTotal: usage(item, cursorStore.snapshot?.total)
        case .cursorAuto: usage(item, cursorStore.snapshot?.auto)
        case .cursorAPI: usage(item, cursorStore.snapshot?.api)
        case .networkDownload: networkSpeed(item, speedTest.result?.download)
        case .networkUpload: networkSpeed(item, speedTest.result?.upload)
        case .diskRead: diskSpeed(item, diskMonitor.disk?.inbound)
        case .diskWrite: diskSpeed(item, diskMonitor.disk?.outbound)
        }
    }

    /// Turns yellow or red while the window is running ahead of an even pace.
    private func usage(_ item: MenuBarItem, _ window: CodexUsageWindow?) -> MenuBarSegment {
        guard let window else {
            return MenuBarSegment(source: item.source, label: item.shortLabel, value: "—", color: .secondaryLabelColor)
        }
        let paceColor = settings.colorsMenuBarByPace ? Self.overPaceColor(window.pace) : nil
        return MenuBarSegment(
            source: item.source,
            label: item.shortLabel,
            value: window.formattedPercent,
            color: paceColor ?? .labelColor
        )
    }

    private func networkSpeed(_ item: MenuBarItem, _ bitsPerSecond: Double?) -> MenuBarSegment {
        MenuBarSegment(
            source: item.source,
            label: item.shortLabel,
            value: bitsPerSecond.map(SpeedSample.formatBits) ?? "—",
            color: bitsPerSecond == nil ? .secondaryLabelColor : .labelColor
        )
    }

    /// Reserves the widest value's width since disk speed changes every second.
    private func diskSpeed(_ item: MenuBarItem, _ bytesPerSecond: Double?) -> MenuBarSegment {
        MenuBarSegment(
            source: item.source,
            label: item.shortLabel,
            value: bytesPerSecond.map(SpeedSample.formatBytes) ?? "—",
            color: bytesPerSecond == nil ? .secondaryLabelColor : .labelColor,
            widthTemplate: "\(item.shortLabel ?? "") 888 MB/s"
        )
    }

    private static func overPaceColor(_ pace: UsagePace) -> NSColor? {
        switch pace {
        case .nearPace:
            return .systemYellow
        case .aheadOfPace:
            return .systemRed
        case .onPace, .neutral:
            return nil
        }
    }

    private func showSettings() {
        popover.performClose(nil)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty unified toolbar gives the larger corner radius and drops the traffic lights onto the title row.
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            let host = NSHostingController(
                rootView: SettingsView(
                    settings: settings,
                    claudeStore: store,
                    codexStore: codexStore,
                    openCodeStore: openCodeStore,
                    openRouterStore: openRouterStore,
                    grokStore: grokStore,
                    cursorStore: cursorStore,
                    speedTest: speedTest
                )
            )
            host.sizingOptions = []
            window.contentViewController = host
            // Frame, not content size: with a toolbar the content size gets the toolbar height added on top.
            window.setFrame(NSRect(x: 0, y: 0, width: 640, height: 600), display: false)
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshEnabledIfStale()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startOutsideClickMonitor()
            updateDiskSampling()
        }
    }

    /// Clicks in other apps aren't delivered to us, so `.transient` alone can miss them.
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover.performClose(nil)
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        updateDiskSampling()
    }
}
