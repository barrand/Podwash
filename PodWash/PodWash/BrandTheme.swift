//
//  BrandTheme.swift
//  PodWash
//
//  Slice 21 — Semantic brand tokens (ADR-019). Dark appearance only.
//

import SwiftUI

/// Semantic brand tokens — dark appearance only (Slice 21 / ADR-019).
enum BrandTheme {
    /// Home-screen + in-app wordmark label; must equal `CFBundleDisplayName`.
    static let approvedDisplayName: String = "PodWash"

    // MARK: sRGB components (0…1) — test contract AC1 (± 0.001)

    static let primaryRed: Double = 0.165
    static let primaryGreen: Double = 0.616
    static let primaryBlue: Double = 0.561

    static let accentRed: Double = 0.914
    static let accentGreen: Double = 0.769
    static let accentBlue: Double = 0.416

    static let surfaceRed: Double = 0.059
    static let surfaceGreen: Double = 0.078
    static let surfaceBlue: Double = 0.098

    static let onPrimaryRed: Double = 1.0
    static let onPrimaryGreen: Double = 1.0
    static let onPrimaryBlue: Double = 1.0

    static let onSurfaceRed: Double = 0.910
    static let onSurfaceGreen: Double = 0.918
    static let onSurfaceBlue: Double = 0.929

    // MARK: SwiftUI colors (built from the components above)

    static var primary: Color {
        Color(.sRGB, red: primaryRed, green: primaryGreen, blue: primaryBlue, opacity: 1)
    }

    static var accent: Color {
        Color(.sRGB, red: accentRed, green: accentGreen, blue: accentBlue, opacity: 1)
    }

    static var surface: Color {
        Color(.sRGB, red: surfaceRed, green: surfaceGreen, blue: surfaceBlue, opacity: 1)
    }

    static var onPrimary: Color {
        Color(.sRGB, red: onPrimaryRed, green: onPrimaryGreen, blue: onPrimaryBlue, opacity: 1)
    }

    static var onSurface: Color {
        Color(.sRGB, red: onSurfaceRed, green: onSurfaceGreen, blue: onSurfaceBlue, opacity: 1)
    }
}
