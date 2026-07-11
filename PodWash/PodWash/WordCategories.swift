//
//  WordCategories.swift
//  PodWash
//
//  Slice 13 — Seeded category IDs and word lists (ADR-010).
//

import Foundation

/// Stable category IDs and seeded word lists for Settings composition.
/// Inflections are enumerated explicitly (no stemming) — matching-spec §7.
/// Entries are stored in WordMatcher-normalized form (lowercase; no leading/
/// trailing non-[a-z0-9]; interior punctuation/leet kept).
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
            return fWordSeeds
        case "sWord":
            return sWordSeeds
        case "dWord":
            return dWordSeeds
        case "racialSlurs":
            return racialSlurSeeds
        case "godsName":
            return godsNameSeeds
        case "otherProfanity":
            return otherProfanitySeeds
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

    // MARK: - fWord

    private static let fWordSeeds: [String] = [
        // Plain forms + compounds + inflections
        "clusterfuck",
        "clusterfucked",
        "clusterfucking",
        "fuck",
        "fuckable",
        "fuckboy",
        "fucked",
        "fucker",
        "fuckers",
        "fuckery",
        "fuckface",
        "fuckhead",
        "fuckin",
        "fucking",
        "fucks",
        "fuckup",
        "fuckwit",
        "motherfuck",
        "motherfucked",
        "motherfucker",
        "motherfuckers",
        "motherfuckin",
        "motherfucking",
        "ratfuck",
        // Obfuscations / leet / creative spellings (interior symbols kept)
        "f*ck",
        "f*cked",
        "f*cker",
        "f*ckers",
        "f*cking",
        "f*cks",
        "f**k",
        "f**ked",
        "f**ker",
        "f**king",
        "fck",
        "fcked",
        "fcker",
        "fcking",
        "fcuk",
        "fcuking",
        "fuk",
        "fuked",
        "fuker",
        "fuking",
        "fvck",
        "fvcked",
        "fvcker",
        "fvcking",
        "motherf*ck",
        "motherf*cker",
        "motherf*ckers",
        "motherf*cking",
        "phuck",
        "phucked",
        "phucker",
        "phucking",
    ]

    // MARK: - sWord

    private static let sWordSeeds: [String] = [
        // Plain forms + compounds + inflections
        "apeshit",
        "batshit",
        "bullshit",
        "bullshits",
        "bullshitted",
        "bullshitting",
        "chickenshit",
        "dipshit",
        "dipshits",
        "horseshit",
        "shit",
        "shitbag",
        "shitface",
        "shitfaced",
        "shithead",
        "shitheads",
        "shithole",
        "shitholes",
        "shits",
        "shitstain",
        "shitter",
        "shitting",
        "shitty",
        // Obfuscations / leet / creative spellings (interior symbols kept)
        "bullsh!t",
        "bullsh*t",
        "bullsh1t",
        "sh!t",
        "sh!thead",
        "sh!thole",
        "sh!ts",
        "sh!tty",
        "sh*t",
        "sh*thead",
        "sh*thole",
        "sh*ts",
        "sh*tty",
        "sh1t",
        "sh1thead",
        "sh1thole",
        "sh1ts",
        "sh1tty",
    ]

    // MARK: - dWord

    private static let dWordSeeds: [String] = [
        // Plain forms + inflections
        "damn",
        "dammit",
        "damnable",
        "damnation",
        "damned",
        "damning",
        "damnit",
        // Obfuscations
        "d@mn",
        "d4mn",
    ]

    // MARK: - racialSlurs

    private static let racialSlurSeeds: [String] = [
        // Plain forms
        "chink",
        "chinks",
        "kike",
        "kikes",
        "nigger",
        "niggers",
        "spic",
        "spics",
        // Obfuscations / leet
        "ch1nk",
        "ch1nks",
        "ch*nk",
        "k1ke",
        "k1kes",
        "k*ke",
        "n!gger",
        "n!ggers",
        "n*gger",
        "n*ggers",
        "n1gger",
        "n1ggers",
        "sp1c",
        "sp1cs",
        "sp*c",
    ]

    // MARK: - godsName

    private static let godsNameSeeds: [String] = [
        // Plain forms + compounds
        "christ",
        "goddam",
        "goddamn",
        "goddammit",
        "goddamit",
        "goddamned",
        "goddamnit",
        "jeezus",
        "jeezuschrist",
        "jesus",
        "jesuschrist",
        "jesusfuckingchrist",
        // Obfuscations
        "g0ddamn",
        "g0ddammit",
        "godd@mn",
        "j3sus",
        "j3suschrist",
    ]

    // MARK: - otherProfanity

    private static let otherProfanitySeeds: [String] = [
        // Plain forms + compounds + inflections
        "ass",
        "asses",
        "asshat",
        "asshole",
        "assholes",
        "asswipe",
        "bastard",
        "bastards",
        "bitch",
        "bitches",
        "bitching",
        "bitchy",
        "cock",
        "cocks",
        "cocksucker",
        "cocksuckers",
        "crap",
        "crappy",
        "cunt",
        "cunts",
        "dick",
        "dickhead",
        "dickheads",
        "dicks",
        "douche",
        "douchebag",
        "douchebags",
        "piss",
        "pissed",
        "pissing",
        "prick",
        "pricks",
        "pussy",
        "pussies",
        "twat",
        "twats",
        "wank",
        "wanker",
        "wankers",
        // Obfuscations / leet / creative spellings
        "a**hole",
        "a**holes",
        "a*hole",
        "azzhole",
        "azzholes",
        "b!tch",
        "b!tches",
        "b*tch",
        "b*tches",
        "b1tch",
        "b1tches",
        "biatch",
        "biatches",
        "c0ck",
        "c0cks",
        "c*ck",
        "c*nt",
        "d1ck",
        "d1ckhead",
        "d1cks",
        "d*ck",
        "d*ckhead",
    ]
}
