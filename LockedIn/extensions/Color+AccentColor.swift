//
//  Color+AccentColor.swift
//  LockedIn
//
//  LockedIn accent system: exactly one accent color, picked from 5 curated
//  options. The accent appears only in the idle glow, the session arc, and
//  the end-of-session pulse — nowhere else.
//

import SwiftUI
import Defaults

enum FocusAccent: String, CaseIterable, Identifiable, Defaults.Serializable {
    case amber
    case sage
    case mist
    case lavender
    case rose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .amber: "Amber"
        case .sage: "Sage"
        case .mist: "Mist"
        case .lavender: "Lavender"
        case .rose: "Rose"
        }
    }

    var hex: String {
        switch self {
        case .amber: "#E8A87C"
        case .sage: "#A8C09A"
        case .mist: "#8FB8C9"
        case .lavender: "#B5A8D4"
        case .rose: "#D9A5B3"
        }
    }

    var color: Color {
        switch self {
        case .amber: Color(red: 0xE8 / 255, green: 0xA8 / 255, blue: 0x7C / 255) // #E8A87C
        case .sage: Color(red: 0xA8 / 255, green: 0xC0 / 255, blue: 0x9A / 255) // #A8C09A
        case .mist: Color(red: 0x8F / 255, green: 0xB8 / 255, blue: 0xC9 / 255) // #8FB8C9
        case .lavender: Color(red: 0xB5 / 255, green: 0xA8 / 255, blue: 0xD4 / 255) // #B5A8D4
        case .rose: Color(red: 0xD9 / 255, green: 0xA5 / 255, blue: 0xB3 / 255) // #D9A5B3
        }
    }
}

extension Defaults.Keys {
    static let focusAccent = Key<FocusAccent>("focusAccent", default: .amber)
}

extension Color {
    static var focusAccent: Color {
        Defaults[.focusAccent].color
    }
}
