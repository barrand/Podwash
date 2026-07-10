//
//  WordMatcher.swift
//  PodWash
//
//  Slice 02 — Matching engine. Swift port of docs/specs/matching-spec.md
//  §3 (normalize) and §4 (exact set-membership matching). Ported from the
//  normative spec, NOT from the retired Python prototype.
//

import Foundation

/// Token normalization and exact set-membership matching per matching-spec §3–4.
/// Nonisolated: pure functions used from nonisolated stores (SettingsStore) and tests.
nonisolated enum WordMatcher {

    /// Normalize a raw ASR token per matching-spec §3.
    ///
    /// 1. Lowercase, then trim surrounding whitespace.
    /// 2. Strip leading and trailing runs of any character that is not a
    ///    lowercase ASCII letter (`a-z`) or digit (`0-9`).
    /// 3. Interior characters are left untouched — so `"f*ck"` → `"f*ck"`
    ///    (interior `*` kept) and `"shit's"` → `"shit's"` (interior apostrophe
    ///    kept, and it does NOT equal `"shit"`).
    ///
    /// Note on apostrophes: the spec §3 example table is normative and requires
    /// `"'ship'"` → `"ship"` (leading/trailing apostrophes stripped) while
    /// `"shit's"` → `"shit's"` (interior apostrophe preserved). The boundary
    /// keep-set is therefore `[a-z0-9]`; apostrophes survive only in the
    /// interior. (The prototype's Python regex kept apostrophes in the boundary
    /// class, which contradicts its own worked example — the example table and
    /// AC1 are the acceptance gate, so this port follows them.)
    static func normalize(_ word: String) -> String {
        let lowered = word.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)

        func isBoundaryKeep(_ scalar: Unicode.Scalar) -> Bool {
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
        }

        guard let first = scalars.firstIndex(where: isBoundaryKeep),
              let last = scalars.lastIndex(where: isBoundaryKeep) else {
            return ""
        }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    /// Exact set-membership match per matching-spec §4: `normalized ∈ target`.
    /// No stemming, no substring, no fuzzy matching. The empty string never
    /// matches (real targets never normalize to empty).
    static func matches(_ normalizedWord: String, in targetSet: Set<String>) -> Bool {
        guard !normalizedWord.isEmpty else { return false }
        return targetSet.contains(normalizedWord)
    }

    /// Build a target set by normalizing each raw target word with the same
    /// `normalize(_:)` (spec §4: "target lists are normalized before use").
    /// Empty results are dropped so they can never accidentally match.
    static func normalizedTargetSet<S: Sequence>(_ words: S) -> Set<String>
    where S.Element == String {
        Set(words.map(normalize).filter { !$0.isEmpty })
    }
}
