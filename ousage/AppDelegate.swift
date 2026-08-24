//
//  AppDelegate.swift
//  ousage
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = CodexUsageStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        observeUsage()
        registerLaunchAtLogin()
        store.start()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "Codex usage"
        button.setAccessibilityLabel("Codex usage")
        statusItem = item
        updateStatusTitle()
    }

    private func observeUsage() {
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    private func registerLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard service.status == .notRegistered else { return }

        do {
            try service.register()
        } catch {
            NSLog("Could not register ousage to launch at login: %@", error.localizedDescription)
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        let title = NSMutableAttributedString()
        if let fiveHour = store.snapshot?.fiveHour {
            append(window: fiveHour, label: "5h", to: title)
        }
        if let weekly = store.snapshot?.weekly {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  "))
            }
            append(window: weekly, label: "W", to: title)
        }

        if title.length == 0 {
            title.append(styled("Codex —", color: .secondaryLabelColor))
        }

        button.attributedTitle = title
        button.setAccessibilityValue(store.accessibilitySummary)
    }

    private func append(
        window: CodexUsageWindow,
        label: String,
        to title: NSMutableAttributedString
    ) {
        title.append(styled("\(label) ", color: .labelColor))
        title.append(styled(window.formattedPercent, color: .labelColor))
    }

    private func styled(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .medium
                ),
                .foregroundColor: color,
            ]
        )
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
