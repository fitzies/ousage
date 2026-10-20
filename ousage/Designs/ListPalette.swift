//
//  ListPalette.swift
//  ousage
//
//  Colour options for the compact list design. Each palette maps a usage window's pace
//  (on / near / ahead of pace) to a bar colour and a percent colour.
//

import SwiftUI

enum ListPalette: String, CaseIterable, Identifiable {
    case traffic, graphite, amberAlert, accent, brand, sage, cool

    static let storageKey = "listPalette"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .traffic: "Traffic light"
        case .graphite: "Graphite"
        case .amberAlert: "Amber alert"
        case .accent: "Accent blue"
        case .brand: "Brand colours"
        case .sage: "Soft (sage · sand · coral)"
        case .cool: "Cool (teal · indigo · pink)"
        }
    }

    var detail: String {
        switch self {
        case .traffic: "The original green / yellow / red."
        case .graphite: "No colour at all; heavier grey the closer you get to the limit."
        case .amberAlert: "Grey until it matters, then amber, then orange."
        case .accent: "Everything in the system accent blue; orange only when over pace."
        case .brand: "Each provider's own colour; percent turns orange when over pace."
        case .sage: "Muted, desaturated version of traffic light."
        case .cool: "Teal when fine, indigo when close, pink when over."
        }
    }

    /// Bar fill for a window. `tint` is the provider's brand colour.
    func bar(_ pace: UsagePace, tint: Color) -> Color {
        switch self {
        case .traffic: return pace.designColor
        case .graphite:
            switch pace {
            case .aheadOfPace: return Color.primary.opacity(0.9)
            case .nearPace: return Color.primary.opacity(0.6)
            default: return Color.primary.opacity(0.35)
            }
        case .amberAlert:
            switch pace {
            case .aheadOfPace: return Color(red: 1.0, green: 0.50, blue: 0.20)
            case .nearPace: return Color(red: 0.98, green: 0.74, blue: 0.25)
            default: return Color.primary.opacity(0.4)
            }
        case .accent:
            return pace == .aheadOfPace ? .orange : .accentColor
        case .brand:
            return tint
        case .sage:
            switch pace {
            case .aheadOfPace: return Color(red: 0.88, green: 0.50, blue: 0.45)
            case .nearPace: return Color(red: 0.86, green: 0.72, blue: 0.45)
            case .onPace: return Color(red: 0.50, green: 0.70, blue: 0.56)
            case .neutral: return Color.primary.opacity(0.35)
            }
        case .cool:
            switch pace {
            case .aheadOfPace: return Color(red: 0.93, green: 0.40, blue: 0.68)
            case .nearPace: return Color(red: 0.50, green: 0.52, blue: 0.98)
            case .onPace: return Color(red: 0.22, green: 0.72, blue: 0.78)
            case .neutral: return Color.primary.opacity(0.35)
            }
        }
    }

    /// Colour for the percent label.
    func text(_ pace: UsagePace, tint: Color) -> Color {
        switch self {
        case .traffic, .sage, .cool, .amberAlert:
            return pace == .neutral || (self == .amberAlert && pace == .onPace)
                ? .primary : bar(pace, tint: tint)
        case .graphite:
            return pace == .aheadOfPace ? .primary : .secondary
        case .accent, .brand:
            return pace == .aheadOfPace ? .orange : .primary
        }
    }

    /// Colours for the Settings sidebar icons: Menu bar, Providers, System.
    var settingsTints: (Color, Color, Color) {
        switch self {
        case .traffic: return (.blue, .orange, .green)
        case .graphite: return (Color(white: 0.42), Color(white: 0.32), Color(white: 0.52))
        case .amberAlert: return (Color(white: 0.45), Color(red: 1.0, green: 0.50, blue: 0.20), Color(red: 0.95, green: 0.68, blue: 0.18))
        case .accent: return (.accentColor, .accentColor, .accentColor)
        // Claude coral, Grok indigo, Codex teal.
        case .brand: return (Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.42, green: 0.40, blue: 0.80), Color(red: 0.06, green: 0.64, blue: 0.52))
        case .sage: return (Color(red: 0.50, green: 0.70, blue: 0.56), Color(red: 0.86, green: 0.66, blue: 0.40), Color(red: 0.85, green: 0.50, blue: 0.45))
        case .cool: return (Color(red: 0.50, green: 0.52, blue: 0.98), Color(red: 0.93, green: 0.40, blue: 0.68), Color(red: 0.22, green: 0.72, blue: 0.78))
        }
    }
}
