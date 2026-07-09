//
//  WordProfiles.swift
//  PodWash
//
//  Slice 02 — Matching engine. Seeded default category word lists per
//  docs/specs/matching-spec.md §7. Lists are user-configurable at runtime;
//  these are the shipped starting points and the values used by fixtures.
//

import Foundation

/// Seeded category word lists (matching-spec §7). Inflections are enumerated
/// explicitly because matching is exact set membership (no stemming).
enum WordProfiles {

    /// Test/clean-language profile. Also the prototype's default `TARGET_WORDS`.
    static let harmless: [String] = [
        "freak", "freaking", "ship", "shipped",
    ]

    /// Seed profanity profile.
    static let profanity: [String] = [
        "fuck", "fucked", "fucker", "fuckers", "fucking", "fucks",
        "shit", "shits", "shitty", "bullshit",
    ]
}
