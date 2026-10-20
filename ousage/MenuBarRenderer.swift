//
//  MenuBarRenderer.swift
//  ousage
//

import AppKit

struct MenuBarSegment {
    let source: MenuBarSource
    let label: String?
    let value: String
    var color: NSColor = .labelColor
    /// Reserves the width of this text so values that change every second don't shift the menu bar.
    var widthTemplate: String? = nil
}

/// Draws the status item as one image. Colors resolve when drawn, so it follows the menu bar's appearance.
enum MenuBarRenderer {
    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 4
    private static let groupGap: CGFloat = 9

    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    static func image(for segments: [MenuBarSegment], showsIcons: Bool) -> NSImage? {
        guard !segments.isEmpty else { return nil }

        let space = width(of: " ")
        var layout: [(segment: MenuBarSegment, icon: NSImage?, x: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0

        for (index, segment) in segments.enumerated() {
            let startsGroup = index == 0 || segments[index - 1].source != segment.source
            if index > 0 {
                x += startsGroup ? groupGap : space * 1.5
            }

            var groupIcon: NSImage?
            if showsIcons, startsGroup, let image = icon(for: segment.source) {
                groupIcon = image
                x += iconSize + iconGap
            }

            let textWidth = max(width(of: text(for: segment)), segment.widthTemplate.map { width(of: $0) } ?? 0)
            layout.append((segment, groupIcon, x, ceil(textWidth)))
            x += ceil(textWidth)
        }

        let size = NSSize(width: ceil(x), height: NSStatusBar.system.thickness)
        let image = NSImage(size: size, flipped: false) { rect in
            for entry in layout {
                if let icon = entry.icon {
                    let iconRect = NSRect(
                        x: entry.x - iconGap - iconSize,
                        y: (rect.height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    tinted(icon, size: iconRect.size).draw(in: iconRect)
                }
                draw(entry.segment, x: entry.x, width: entry.width, height: rect.height)
            }
            return true
        }
        image.cacheMode = .never
        return image
    }

    private static func text(for segment: MenuBarSegment) -> String {
        [segment.label, segment.value].compactMap { $0 }.joined(separator: " ")
    }

    /// The label sits on the left and the value on the right of the reserved width.
    private static func draw(_ segment: MenuBarSegment, x: CGFloat, width: CGFloat, height: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: segment.color]
        let value = NSAttributedString(string: segment.value, attributes: attributes)
        let y = (height - value.size().height) / 2

        if let label = segment.label {
            NSAttributedString(string: label, attributes: attributes).draw(at: NSPoint(x: x, y: y))
        }
        value.draw(at: NSPoint(x: x + width - value.size().width, y: y))
    }

    private static func width(of text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static func icon(for source: MenuBarSource) -> NSImage? {
        switch source {
        case .provider(let provider):
            return NSImage(named: provider.icon)
        case .system(let monitor):
            let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .medium)
            return NSImage(systemSymbolName: monitor.symbol, accessibilityDescription: monitor.title)?
                .withSymbolConfiguration(configuration)
        }
    }

    /// Fits the icon's aspect ratio into `size` and fills it with the label color.
    private static func tinted(_ icon: NSImage, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width / icon.size.width, rect.height / icon.size.height)
            let drawSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(
                x: (rect.width - drawSize.width) / 2,
                y: (rect.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
