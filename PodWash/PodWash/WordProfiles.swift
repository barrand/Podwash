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
nonisolated enum WordProfiles {

    /// Test/clean-language profile. Also the prototype's default `TARGET_WORDS`.
    static let harmless: [String] = [
        "freak", "freaking", "ship", "shipped",
    ]

    /// Seed profanity profile — union of `WordCategories` fWord + sWord seeds
    /// (superset of matching-spec §7 base forms) for fixture consistency.
    static let profanity: [String] = {
        var seen = Set<String>()
        var union: [String] = []
        for word in WordCategories.words(for: "fWord") + WordCategories.words(for: "sWord") {
            let key = WordMatcher.normalize(word)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            union.append(word)
        }
        return union
    }()
}
