//
//  WordCategories.swift
//  PodWash
//
//  Slice 13 — Seeded category IDs and word lists (ADR-010).
//

import Foundation

/// Stable category IDs and seeded word lists for Settings composition.
/// Inflections are enumerated explicitly (no stemming) — matching-spec §7.
/// Nonisolated: SettingsStore (also nonisolated) and unit tests read seeds off the
/// module default MainActor isolation.
nonisolated enum WordCategories {

    /// Stable display / persistence order.
    static let allIDs: [String] = [
        "dWord", "fWord", "godsName", "otherProfanity", "racialSlurs", "sWord",
    ]

    /// PRD default profile — exactly these four ON (AC1).
    static let defaultEnabledIDs: Set<String> = [
        "dWord", "fWord", "racialSlurs", "sWord",
    ]

    static func words(for categoryID: String) -> [String] {
        switch categoryID {
        case "fWord":
            return [
                "fuck", "fucked", "fucker", "fuckers", "fucking", "fucks",
            ]
        case "sWord":
            // Spec §7 S-word subset — exactly 4 (AC2 count delta).
            return ["shit", "shits", "shitty", "bullshit"]
        case "dWord":
            return ["damn", "damned", "dammit", "damnit"]
        case "racialSlurs":
            return ["nigger", "niggers", "chink", "spic", "kike"]
        case "godsName":
            return ["goddamn", "goddammit", "jesuschrist"]
        case "otherProfanity":
            return ["ass", "asshole", "bitch", "bastard", "crap"]
        default:
            return []
        }
    }

    static func displayTitle(for categoryID: String) -> String {
        switch categoryID {
        case "dWord": return "D-word"
        case "fWord": return "F-word"
        case "sWord": return "S-word"
        case "racialSlurs": return "Racial slurs"
        case "godsName": return "God's name in vain"
        case "otherProfanity": return "Other profanity"
        default: return categoryID
        }
    }
}
