//
//  ContentSegmenting.swift
//  PodWash
//
//  Jev schema-v2 typed interruption response mapped to playback intervals.
//

import Foundation

nonisolated enum ContentReason: String, Codable, CaseIterable, Sendable {
    case paidAd = "paid_ad"
    case underwriting
    case crossShowPromo = "cross_show_promo"
    case publisherPromo = "publisher_promo"
    case membershipAppeal = "membership_appeal"
    case engagementRequest = "engagement_request"
    case productionCredit = "production_credit"
    case networkID = "network_id"
    case signoff
}

nonisolated enum SkipPreset: String, Codable, CaseIterable, Sendable {
    case obvious
    case more
    case most

    var enabledReasons: Set<ContentReason> {
        switch self {
        case .obvious:
            return [.paidAd, .underwriting]
        case .more:
            return [.paidAd, .underwriting, .crossShowPromo, .publisherPromo, .membershipAppeal]
        case .most:
            return Set(ContentReason.allCases)
        }
    }

    func removes(_ segment: ContentSegment) -> Bool {
        !enabledReasons.isDisjoint(with: segment.reasons)
    }
}

/// A complete typed interruption span returned by the pinned Jev pipeline.
nonisolated struct ContentSegment: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    static let pipelineVersion = "jev-1.13.0:typed-blocks-v7.1:2"

    let startSentenceID: Int
    let endSentenceID: Int
    let start: Double
    let end: Double
    let reasons: Set<ContentReason>

    init(
        start: Double,
        end: Double,
        startSentenceID: Int = 0,
        endSentenceID: Int = 0,
        reasons: Set<ContentReason> = [.paidAd]
    ) {
        self.startSentenceID = startSentenceID
        self.endSentenceID = endSentenceID
        self.start = start
        self.end = end
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case startSentenceID = "start_sentence_id"
        case endSentenceID = "end_sentence_id"
        case start, end, reasons
    }
}
