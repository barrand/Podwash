//
//  HTMLDescriptionText.swift
//  PodWash
//
//  Renders the HTML commonly supplied in podcast RSS channel descriptions.
//

import SwiftUI
import UIKit

enum HTMLDescriptionText {
    /// Converts RSS HTML into an attributed string for SwiftUI. If a feed supplies
    /// malformed HTML, retain its original text instead of losing the description.
    static func attributedString(from source: String) -> AttributedString {
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

        return attributed
    }
}
