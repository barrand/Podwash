//
//  SuperSeekBarAXParsing.swift
//  PodWashUITests
//
//  Slice 33 — Shared parsers for complete-bar adBands AX grammar (slice-33-ux.md).
//

import Foundation

enum SuperSeekBarAXParsing {

    /// Parses adBands count and normalized band ranges from complete-bar AX value.
    static func adBandSummary(
        from barValue: String
    ) -> (count: Int, bands: [(start: Double, end: Double)], muteMarkers: Int)? {
        guard barValue.hasPrefix("adBands:") else { return nil }
        let parts = barValue.split(separator: ",")
        guard let countPart = parts.first,
              countPart.hasPrefix("adBands:"),
              let count = Int(countPart.dropFirst("adBands:".count))
        else { return nil }

        var bands: [(Double, Double)] = []
        var muteMarkers: Int?
        for token in parts.dropFirst() {
            if token.hasPrefix("muteMarkers:") {
                muteMarkers = Int(token.dropFirst("muteMarkers:".count))
                break
            }
            let edges = token.split(separator: "-")
            guard edges.count == 2,
                  let start = Double(edges[0]),
                  let end = Double(edges[1])
            else { return nil }
            bands.append((start, end))
        }
        guard let muteMarkers, bands.count == count else { return nil }
        return (count, bands, muteMarkers)
    }

    /// True when legacy segment triple is absent (in-flight + post-slice complete guard).
    static func lacksSegmentTriple(_ barValue: String?) -> Bool {
        guard let barValue else { return true }
        return !barValue.contains("ready:")
            && !barValue.contains("processing:")
            && !barValue.contains("pending:")
    }

    /// Denormalize first ad band end to wall seconds for preroll asserts.
    static func firstAdBandEndSeconds(from barValue: String, duration: Double) -> Double? {
        guard let summary = adBandSummary(from: barValue),
              let first = summary.bands.first
        else { return nil }
        return first.end * duration
    }

    static func muteMarkerCount(from barValue: String) -> Int? {
        guard let summary = adBandSummary(from: barValue) else { return nil }
        return summary.muteMarkers
    }
}
