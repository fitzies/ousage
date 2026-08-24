//
//  ContentView.swift
//  ousage
//
//  Created by Oli Fitzgerald on 23/8/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: CodexUsageStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                if let fiveHour = store.snapshot?.fiveHour {
                    UsageLine(title: "5h", window: fiveHour)
                }

                if store.snapshot?.fiveHour != nil, store.snapshot?.weekly != nil {
                    Divider()
                }

                if let weekly = store.snapshot?.weekly {
                    UsageLine(title: "Weekly", window: weekly)
                }

                if store.snapshot?.fiveHour == nil, store.snapshot?.weekly == nil {
                    Text(store.message ?? "Checking Codex usage…")
                        .font(.caption)
                        .foregroundStyle(store.message == nil ? Color.secondary : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            HStack {
                Text(store.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    store.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("Refresh Codex usage")
                .accessibilityLabel("Refresh Codex usage")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit ousage")
                .accessibilityLabel("Quit ousage")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 320)
        .onAppear {
            store.start()
            store.refreshIfStale()
        }
    }
}

private struct UsageLine: View {
    let title: String
    let window: CodexUsageWindow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(window.formattedPercent)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(window.pace))

            if let allowance = window.formattedPaceAllowance {
                Text("· \(allowance) pace")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("Usage available by now at an even pace")
            }

            Spacer(minLength: 8)

            Text(window.resetDescription ?? "Reset unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let allowance = window.formattedPaceAllowance.map { ", \($0) evenly paced allowance" } ?? ""
        return "\(window.formattedPercent)\(allowance), \(window.resetDescription ?? "reset unknown")"
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
