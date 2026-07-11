//
//  SkipOverridePlaybackView.swift
//  PodWash
//
//  Slice 19 — Player chrome hosting skip-override banner (slice-19-ux.md).
//

import SwiftUI

/// Playback controls with a transient unrelated-content skip-override banner.
struct SkipOverridePlaybackView: View {
    @Bindable var engine: PlaybackEngine

    @State private var bannerSkippedSeconds: Int?
    @State private var pendingOverrideInterval: CensorInterval?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if let seconds = bannerSkippedSeconds {
                SkipOverrideBanner(skippedSeconds: seconds) {
                    if let interval = pendingOverrideInterval {
                        engine.overrideUnrelatedContentSkip(interval)
                    }
                    bannerSkippedSeconds = nil
                    pendingOverrideInterval = nil
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            PlaybackControlsView(engine: engine)
        }
        .onAppear {
            // Wire the callback before auto-play so the stub skip at 2.0 s cannot
            // fire into a nil handler (RootView must not play before this runs).
            engine.onUnrelatedContentSkip = { interval, skippedSeconds in
                pendingOverrideInterval = interval
                bannerSkippedSeconds = Int(skippedSeconds.rounded())
            }
            if !engine.isPlaying {
                engine.play()
            }
        }
        .onChange(of: engine.uiRefreshToken) { _, _ in
            dismissBannerIfPastSegmentEnd()
        }
    }

    private func dismissBannerIfPastSegmentEnd() {
        guard let interval = pendingOverrideInterval else { return }
        engine.refreshCurrentTime()
        // Skip landing is in [end − 0.1, end]; only dismiss once playback has
        // *passed* the segment (strictly greater), or the banner vanishes on show.
        if engine.currentTime > interval.end {
            bannerSkippedSeconds = nil
            pendingOverrideInterval = nil
        }
    }
}
