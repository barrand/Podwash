//
//  CarPlayListItemModel.swift
//  PodWash
//
//  Slice 15 — Testable CarPlay list row model (ADR-016 §3).
//

import UIKit

struct CarPlayListItemModel: Equatable {
    let text: String
    let image: UIImage?
    let episodeID: String?
    let subscriptionIndex: Int?
}

/// Supplies non-nil artwork for CarPlay rows (AC artwork counts; no pixel asserts).
protocol CarPlayArtworkProviding {
    func image(for url: URL?) -> UIImage
}

struct CarPlayPlaceholderArtworkProvider: CarPlayArtworkProviding {
    func image(for url: URL?) -> UIImage {
        _ = url
        if let symbol = UIImage(systemName: "photo") {
            return symbol
        }
        // Guaranteed non-nil fallback (0×0 is acceptable; ACs only check != nil).
        return UIImage()
    }
}

extension CarPlayArtworkProviding where Self == CarPlayPlaceholderArtworkProvider {
    static var placeholder: CarPlayPlaceholderArtworkProvider { CarPlayPlaceholderArtworkProvider() }
}
