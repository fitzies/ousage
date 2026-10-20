//
//  DesignPreviewRenderer.swift
//  ousage
//
//  Debug only. Renders each design concept with sample data to PNGs so they can be compared
//  without clicking around. Run the built app with `-ousageRenderDesigns /output/dir`.
//

#if DEBUG
import AppKit
import SwiftUI

enum DesignPreviewRenderer {
    static let launchKey = "ousageRenderDesigns"

    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = PopoverModel.sample()
        let variants = DesignVariant.allCases.filter { $0 != .classic }

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"

            for variant in variants {
                let view = PreviewFrame(scheme: scheme) {
                    DesignVariantView(variant: variant, model: model)
                }
                write(view, scheme: scheme, to: directory.appendingPathComponent("\(variant.rawValue)-\(suffix).png"))
            }

            let sheet = PreviewFrame(scheme: scheme, padding: 24) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(variants) { variant in
                        VStack(spacing: 10) {
                            Text(variant.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(variant.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            DesignVariantView(variant: variant, model: model)
                                .popoverChrome(scheme: scheme)
                        }
                        .frame(width: variant.width)
                    }
                }
            }
            write(sheet, scheme: scheme, to: directory.appendingPathComponent("all-variants-\(suffix).png"))

            for palette in ListPalette.allCases {
                let view = PreviewFrame(scheme: scheme) {
                    ListDesign(model: model, paletteOverride: palette)
                        .frame(width: DesignVariant.list.width)
                }
                write(view, scheme: scheme, to: directory.appendingPathComponent("list-\(palette.rawValue)-\(suffix).png"))
            }
        }
    }

    private static func write<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                NSLog("Could not render %@", url.lastPathComponent)
                return
            }
            do {
                try png.write(to: url)
                NSLog("Wrote %@", url.path)
            } catch {
                NSLog("Could not write %@: %@", url.path, error.localizedDescription)
            }
        }
    }
}

/// ImageRenderer can't draw the popover's vibrancy, so stand in a flat window-like backdrop.
private struct PreviewFrame<Content: View>: View {
    let scheme: ColorScheme
    var padding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

private extension View {
    func popoverChrome(scheme: ColorScheme) -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.985))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 14, y: 6)
    }
}
#endif
