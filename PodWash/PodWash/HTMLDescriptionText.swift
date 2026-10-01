//
//  HTMLDescriptionText.swift
//  PodWash
//
//  Renders the HTML commonly supplied in podcast RSS channel descriptions.
//

import SwiftUI
import UIKit

enum HTMLDescriptionText {
    private static var converted: [String: AttributedString] = [:]
    /// Converts RSS HTML into an attributed string for SwiftUI. If a feed supplies
    /// malformed HTML, retain its original text instead of losing the description.
    static func attributedString(from source: String) -> AttributedString {
        // NSHTMLReader enters a nested WebKit run loop. Repeating it during
        // playback-driven SwiftUI renders can stall player and accessibility
        // updates. Plain RSS descriptions need no importer; rich ones convert once.
        guard source.contains("<") || source.contains("&") else { return AttributedString(source) }
        if let cached = converted[source] { return cached }
        guard let data = source.data(using: .utf8),
              let html = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ),
              let attributed = try? AttributedString(html, including: \.uiKit)
        else {
            return AttributedString(source)
        }

        if converted.count >= 64 { converted.removeAll(keepingCapacity: true) }
        converted[source] = attributed
        return attributed
    }
}
