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
        "fuckbag",
        "fuckboy",
        "fuckboys",
        "fuckbucket",
        "fuckery",
        "fuckface",
        "fuckfaces",
        "fuckhead",
        "fuckheads",
        "fuckhole",
        "fuckin",
        "fucking",
        "fuckinghell",
        "fuckingshit",
        "fucknut",
        "fucks",
        "fuckstick",
        "fucktard",
        "fuckup",
        "fuckups",
        "fuckwad",
        "fuckwit",
        "fuckwits",
        "fucked",
        "fucker",
        "fuckers",
        "unfuckingbelievable",
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
        "dogshit",
        "dipshit",
        "dipshits",
        "dumbshit",
        "eatshit",
        "horseshit",
        "jackshit",
        "no-shit",
        "noshit",
        "shite",
        "shites",
        "shit",
        "shitbag",
        "shitbags",
        "shitbox",
        "shitboxes",
        "shitcanned",
        "shitcan",
        "shitcans",
        "shitface",
        "shitfaced",
        "shitfaces",
        "shitfit",
        "shithead",
        "shitheads",
        "shithole",
        "shitholes",
        "shitless",
        "shitload",
        "shitloads",
        "shitshow",
        "shitshows",
        "shitstorm",
        "shitstorms",
        "shits",
        "shitstain",
        "shitstains",
        "shitter",
        "shitters",
        "shitting",
        "shittiest",
        "shitty",
        "shittyass",
        "toughshit",
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
        "damnable",
        "damnably",
        "damndest",
        "damned",
        "damnedest",
        "damning",
        "damns",
        "dammit",
        "damnation",
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
        "asshats",
        "asshole",
        "assholes",
        "assload",
        "assloads",
        "asswipe",
        "asswipes",
        "badass",
        "badasses",
        "bastard",
        "bastards",
        "bastardized",
        "bastardizing",
        "bitch",
        "bitches",
        "bitching",
        "bitchslap",
        "bitchslapped",
        "bitchy",
        "cock",
        "cocks",
        "cockhead",
        "cockheads",
        "cockshit",
        "cocksucker",
        "cocksuckers",
        "crapola",
        "crap",
        "crappy",
        "cunt",
        "cunts",
        "cuntface",
        "cuntfaces",
        "cuntish",
        "dickbag",
        "dickbags",
        "dick",
        "dickhead",
        "dickheads",
        "dicks",
        "dickwad",
        "dickwads",
        "douche",
        "douchebag",
        "douchebags",
        "douchey",
        "jackass",
        "jackasses",
        "piss",
        "pisshead",
        "pissheads",
        "pissoff",
        "pissed",
        "pissing",
        "pissy",
        "prick",
        "pricks",
        "prickhead",
        "prickheads",
        "pussy",
        "pussies",
        "pussyass",
        "twat",
        "twats",
        "twatwaffle",
        "twatwaffles",
        "wank",
        "wanker",
        "wankers",
        "wanking",
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
