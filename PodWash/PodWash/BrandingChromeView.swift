//
//  BrandingChromeView.swift
//  PodWash
//
//  Slice 21 — Deterministic branding fixture chrome (slice-21-ux.md).
//

import SwiftUI

/// Pushed Settings destination for branding fixture (toolbar Button → navigationDestination).
private enum BrandingSettingsRoute: Hashable, Identifiable {
    case settings
    var id: Self { self }
}

/// Fixture-only surface for `-UITestFixtureBranding`: wordmark, surface sentinel,
/// playback controls, and hittable settings entry (no TabView / network).
struct BrandingChromeView: View {
    @Bindable var engine: PlaybackEngine
    let settingsStore: SettingsStore

    @State private var settingsRoute: BrandingSettingsRoute?

    var body: some View {
        NavigationStack {
            ZStack {
                BrandTheme.surface
                    .ignoresSafeArea()

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("themePrimarySurface")
                    .accessibilityLabel("Brand surface")
                    .accessibilityValue("1")
                    .allowsHitTesting(false)

                VStack(spacing: 32) {
                    Text(BrandTheme.approvedDisplayName)
                        .font(.headline)
                        .foregroundStyle(BrandTheme.onSurface)
                        .accessibilityIdentifier("brandWordmark")
                        .accessibilityLabel(BrandTheme.approvedDisplayName)

                    PlaybackControlsView(engine: engine)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationDestination(item: $settingsRoute) { _ in
                SettingsView(store: settingsStore)
                    .background(BrandTheme.surface)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    settingsRoute = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(BrandTheme.onSurface)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settingsButton")
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens cleaning and playback defaults.")
                .padding(.trailing, 8)
                .safeAreaPadding(.top)
            }
        }
    }
}
