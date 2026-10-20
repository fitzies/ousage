//
//  ConceptB_List.swift
//  ousage
//
//  Concept B: dense sectioned list, in the openusage mould. Small type, hairline dividers,
//  a full-width bar under each window, and a sticky footer with the last update and controls.
//

import SwiftUI

struct ListDesign: View {
    let model: PopoverModel
    /// Set by the preview renderer; the app uses the palette chosen in Settings.
    var paletteOverride: ListPalette? = nil
    @AppStorage(ListPalette.storageKey) private var storedPalette = ListPalette.brand

    private var palette: ListPalette { paletteOverride ?? storedPalette }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.panels.enumerated()), id: \.element.id) { index, panel in
                if index > 0 {
                    Divider().padding(.horizontal, 12)
                }
                ListSection(panel: panel, palette: palette)
            }

            if model.isEmpty {
                Text("Nothing to show. Turn on providers in Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            ListFooter(model: model)
        }
        .padding(.top, 4)
    }
}

private struct ListSection: View {
    let panel: PopoverModel.Panel
    let palette: ListPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DesignGlyph(panel: panel, size: 12)
                    .foregroundStyle(.primary)
                Text(panel.title)
                    .font(.system(size: 12, weight: .semibold))
                if let subtitle = panel.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if panel.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let relative = designRelative(panel.fetchedAt), !isMonitor {
                    Text(relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)

            if let placeholder = panel.placeholder {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if isMonitor {
                HStack(spacing: 0) {
                    ForEach(panel.metrics) { metric in
                        HStack(spacing: 5) {
                            Image(systemName: symbol(for: metric.label))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(metric.text ?? "—")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(metric.text == nil ? .secondary : .primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            } else {
                ForEach(panel.metrics) { metric in
                    switch metric.kind {
                    case .usage(let window):
                        ListUsageRow(label: metric.label, window: window, palette: palette, tint: panel.tint)
                    case .value(let value):
                        HStack {
                            Text(metric.label).font(.system(size: 12))
                            Spacer()
                            Text(value ?? "—")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(value == nil ? .secondary : .primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 9)
                    }
                }
            }

            DesignNotes(panel: panel)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var isMonitor: Bool {
        if case .monitor = panel.source { return true }
        return false
    }

    private func symbol(for label: String) -> String {
        switch label {
        case "Download", "Read": "arrow.down"
        default: "arrow.up"
        }
    }
}

private struct ListUsageRow: View {
    let label: String
    let window: CodexUsageWindow?
    let palette: ListPalette
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                if let window {
                    Text(window.formattedPercent)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(palette.text(window.pace, tint: tint))
                    if let reset = window.designShortReset {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(reset)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            DesignBar(window: window, height: 3, color: window.map { palette.bar($0.pace, tint: tint) })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue(helpText)
    }

    private var helpText: String {
        guard let window else { return "Unavailable" }
        let pace = window.designPaceDelta.map { ", \($0)" } ?? ""
        return "\(window.formattedPercent) used\(pace), \(window.resetDescription ?? "reset unknown")"
    }
}

private struct ListFooter: View {
    let model: PopoverModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.latestFetch.flatMap(designRelative).map { "Updated \($0)" } ?? "ousage")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            DesignToolbarButtons(model: model)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) {
            Divider()
        }
        .padding(.top, 2)
    }
}
