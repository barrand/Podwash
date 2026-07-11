//
//  SkipOverrideBanner.swift
//  PodWash
//
//  Slice 19 — Transient skip-override affordance (slice-19-ux.md, ADR-013 §3.6).
//

import SwiftUI

/// Full-width tappable strip shown after an unrelated-content `.skip` lands.
struct SkipOverrideBanner: View {
    let skippedSeconds: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("Skipped ~\(skippedSeconds)s — tap to play")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("skipOverrideBanner")
        .accessibilityLabel("Skipped segment")
        .accessibilityValue("\(skippedSeconds)")
        .accessibilityHint("Tap to play the skipped segment.")
        .accessibilityAddTraits(.isButton)
    }
}
