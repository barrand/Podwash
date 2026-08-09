//
//  SettingsView.swift
//  PodWash
//
//  Slice 13 — Settings screen (slice-13-settings-ux.md, ADR-010 §5).
//

import SwiftUI

struct SettingsView: View {
    private static let privacyPolicyURL = URL(string: "https://podwash-support.web.app/privacy")!
    private static let supportURL = URL(string: "https://podwash-support.web.app/support")!

    @Bindable var store: SettingsStore
    @State private var customWordDraft = ""
    #if DEBUG
    @State private var isCloudProbeRunning = false
    @State private var cloudProbeResult: String?
    #endif
    /// Bumped on category taps so AX values refresh even if Observation is quiet
    /// on the nonisolated SettingsStore (UITest reads accessibilityValue post-tap).
    @State private var categoryChangeToken = 0

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    var body: some View {
        // ScrollView + VStack (not Form/List): Form lazily materializes cells, so
        // off-screen identifiers like categoryToggle_sWord / customWordTextField
        // are absent from the AX tree on short/landscape windows.
        //
        // UITest sims often launch landscape (~402pt tall). Slice 19's unrelated
        // section pushes sWord below the fold with a zero/stale AX frame — taps
        // no-op. ScrollViewReader centers sWord in fixture mode; Button rows
        // accept AX activate without a decorative UISwitch stealing hits.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    cleaningDefaultsSection
                    unrelatedContentSection
                    wordCategoriesSection
                    customWordsSection
                    episodeBehaviorSection
                    privacyAndSupportSection
                    playbackDiagnosticsSection
                    #if DEBUG
                    cloudConnectivityProbeSection
                    #endif
                    buildStampSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                // The shell mini-player may include its preparation shelf, making it
                // substantially taller than the tab bar. Keep the final Settings
                // controls scrollable above that persistent player chrome.
                .padding(.bottom, 160)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard FixtureSettings.isEnabled else { return }
                // Center sWord after first layout so XCTest gets a non-zero frame.
                DispatchQueue.main.async {
                    proxy.scrollTo("scroll_category_sWord", anchor: .center)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // `.contain` keeps child controls queryable while still exposing settingsRoot
        // (same pattern as feed.error / queueList).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsRoot")
        .accessibilityLabel("Settings")
    }

    // MARK: - Sections

    private var cleaningDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cleaning defaults")
                .font(.headline)

            Button(action: cycleCleaningAction) {
                HStack {
                    Text("Default cleaning action")
                    Spacer()
                    Text(store.defaultCleaningAction.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("defaultActionControl")
            .accessibilityLabel("Default cleaning action")
            .accessibilityValue(store.defaultCleaningAction.rawValue)
            .accessibilityHint("Changes the default action for new cleaning sessions.")

            Button(action: cycleMuteOverlayMode) {
                HStack {
                    Text("Mute overlay sound")
                    Spacer()
                    Text(muteOverlayDisplayName(store.muteOverlayMode))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("muteOverlayControl")
            .accessibilityLabel("Mute overlay sound")
            .accessibilityValue(store.muteOverlayMode.rawValue)
            .accessibilityHint("Changes the sound played during muted words. Off is silent.")

            Button(action: cyclePlaybackRate) {
                HStack {
                    Text("Default playback speed")
                    Spacer()
                    Text(PlaybackEngine.accessibilityValue(for: store.defaultPlaybackRate) + "×")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("defaultSpeedButton")
            .accessibilityLabel("Default playback speed")
            .accessibilityValue(PlaybackEngine.accessibilityValue(for: store.defaultPlaybackRate))
            .accessibilityHint("Changes the default playback speed.")
        }
    }

    private var unrelatedContentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ads")
                .font(.headline)

            Toggle(isOn: $store.unrelatedContentEnabled) {
                Text("Skip ads")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("unrelatedContentToggle")
            .accessibilityLabel("Skip ads")
            .accessibilityValue(store.unrelatedContentEnabled ? "1" : "0")
            .accessibilityHint("Skips or mutes segments that seem like ads.")

            Toggle(isOn: $store.cloudTranscriptProcessingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use cloud ad detection")
                    Text("Sends the text from your on-device transcript—not audio—to identify ads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("cloudTranscriptProcessingToggle")
            .accessibilityLabel("Use cloud ad detection")
            .accessibilityValue(store.cloudTranscriptProcessingEnabled ? "1" : "0")

            if store.unrelatedContentEnabled {
                Button(action: cycleUnrelatedContentAction) {
                    HStack {
                        Text("Ads action")
                        Spacer()
                        Text(store.unrelatedContentAction.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("unrelatedContentActionControl")
                .accessibilityLabel("Ads action")
                .accessibilityValue(store.unrelatedContentAction.rawValue)
                .accessibilityHint("Chooses skip or mute for ad segments.")
            }
        }
    }

    private var wordCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word categories")
                .font(.headline)

            // Eager (non-lazy) two-column rows: every categoryToggle_* stays in the AX
            // tree. Fixture ScrollViewReader centers sWord so landscape (~402pt) taps
            // hit a real frame; Button+Image (no UISwitch) so AX activate flips state.
            let ids = WordCategories.allIDs
            ForEach(Array(stride(from: 0, to: ids.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: 6) {
                    categoryToggle(ids[start])
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if start + 1 < ids.count {
                        categoryToggle(ids[start + 1])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func categoryToggle(_ categoryID: String) -> some View {
        // Force body refresh when token bumps (Observation on nonisolated store is quiet).
        let _ = categoryChangeToken
        let enabled = store.isCategoryEnabled(categoryID)
        return Button {
            store.setCategoryEnabled(categoryID, !store.isCategoryEnabled(categoryID))
            categoryChangeToken &+= 1
        } label: {
            HStack(spacing: 4) {
                Text(WordCategories.displayTitle(for: categoryID))
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("categoryToggle_\(categoryID)")
        .accessibilityLabel(WordCategories.displayTitle(for: categoryID))
        .accessibilityValue(enabled ? "1" : "0")
        .accessibilityHint(categoryHint(for: categoryID))
        .accessibilityAddTraits(.isButton)
        // Stable scroll id (not tied to enabled) for ScrollViewReader / fixture centering.
        .id("scroll_category_\(categoryID)")
    }

    private var customWordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom words")
                .font(.headline)

            HStack {
                TextField("Custom word", text: $customWordDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("customWordTextField")
                    .accessibilityLabel("Custom word")
                    .accessibilityHint("Enter a word to add to your cleaning list.")

                Button("Add", action: addCustomWord)
                    .disabled(customWordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("customWordAddButton")
                    .accessibilityLabel("Add custom word")
            }

            if store.customWords.isEmpty {
                Text("No custom words")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.customWords.enumerated()), id: \.offset) { index, word in
                    HStack {
                        Text(word)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            store.removeCustomWord(word)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityIdentifier("customWordRemoveButton_\(index)")
                        .accessibilityLabel("Remove custom word")
                        .accessibilityValue(word)
                        .accessibilityHint("Removes this word from your cleaning list.")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    // Combine so XCTest reads the row label (AC6); remove stays optional.
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("customWordRow_\(index)")
                    .accessibilityLabel(word)
                }
            }
        }
    }

    private var episodeBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Episode behavior")
                .font(.headline)

            Toggle(isOn: $store.smartAutoplayEnabled) {
                Text("Smart autoplay")
            }
            .accessibilityIdentifier("smartAutoplayToggle")
            .accessibilityLabel("Smart autoplay")
            .accessibilityHint("When Up Next is empty, continues across subscriptions.")
            .accessibilityValue(store.smartAutoplayEnabled ? "1" : "0")

            Toggle(isOn: $store.autoDownloadEnabled) {
                Text("Auto-download new episodes")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("autoDownloadToggle")
            .accessibilityLabel("Auto-download new episodes")
            .accessibilityValue(store.autoDownloadEnabled ? "1" : "0")

            Toggle(isOn: $store.autoDeleteAfterPlayedEnabled) {
                Text("Auto-delete after played")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("autoDeleteToggle")
            .accessibilityLabel("Auto-delete after played")
            .accessibilityValue(store.autoDeleteAfterPlayedEnabled ? "1" : "0")
        }
    }

    /// Public links live in Settings alongside the controls that govern cloud
    /// processing. This keeps the Privacy Policy easy to find in-app (Apple
    /// requires it) and gives listeners a direct support path.
    private var privacyAndSupportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy & Support")
                .font(.headline)

            Text("Learn how PodWash handles information or get help.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: Self.privacyPolicyURL) {
                settingsLinkRow(title: "Privacy Policy", icon: "hand.raised")
            }
            .accessibilityIdentifier("privacyPolicyLink")
            .accessibilityLabel("Privacy Policy")
            .accessibilityHint("Opens the PodWash Privacy Policy in your browser.")

            Link(destination: Self.supportURL) {
                settingsLinkRow(title: "Contact Support", icon: "questionmark.circle")
            }
            .accessibilityIdentifier("supportLink")
            .accessibilityLabel("Contact Support")
            .accessibilityHint("Opens the PodWash support page in your browser.")
        }
    }

    private func settingsLinkRow(title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private var playbackDiagnosticsSection: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let _ = PlaybackDiagnostics.contentRevision
            VStack(alignment: .leading, spacing: 8) {
                Text("Playback diagnostics")
                    .font(.headline)

                Text(
                    "Recent play/download events. In Console, filter subsystem "
                        + "com.barrandfarm.PodWash category Playback."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    Text(
                        PlaybackDiagnostics.recentLines.isEmpty
                            ? "No playback events yet. Tap an episode, then play."
                            : PlaybackDiagnostics.recentLines.joined(separator: "\n")
                    )
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("playbackDiagnosticsLog")

                Button("Clear playback log") {
                    PlaybackDiagnostics.clear()
                }
                .accessibilityIdentifier("playbackDiagnosticsClear")
            }
        }
    }

    #if DEBUG
    private var cloudConnectivityProbeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug cloud check")
                .font(.headline)

            Text("Uses a tiny built-in transcript to test Firebase credentials, App Check, Cloud Run, and Gemini without downloading an episode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(isCloudProbeRunning ? "Testing cloud…" : "Test cloud ad detection") {
                runCloudConnectivityProbe()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCloudProbeRunning)
            .accessibilityIdentifier("debugCloudConnectivityProbe")

            if let cloudProbeResult {
                Text(cloudProbeResult)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(cloudProbeResult.hasPrefix("Success") ? .green : .orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("debugCloudConnectivityProbeResult")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func runCloudConnectivityProbe() {
        guard store.cloudTranscriptProcessingEnabled else {
            cloudProbeResult = "Enable Use cloud ad detection first."
            return
        }
        isCloudProbeRunning = true
        cloudProbeResult = nil
        let startedAt = Date()
        let client = CloudAdSpanClient(
            configuration: .applicationDefault(consentGranted: { true })
        )
        let transcript = [
            TimedWord(word: "This", start: 0, end: 0.2),
            TimedWord(word: "is", start: 0.2, end: 0.4),
            TimedWord(word: "a", start: 0.4, end: 0.5),
            TimedWord(word: "connectivity", start: 0.5, end: 1.1),
            TimedWord(word: "check.", start: 1.1, end: 1.4),
        ]
        Task {
            defer { isCloudProbeRunning = false }
            do {
                let spans = try await client.detectAdSpans(
                    in: transcript,
                    episodeID: "debug-cloud-connectivity-check"
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                cloudProbeResult = "Success · spans=\(spans.count) · \(String(format: "%.1f", elapsed))s"
                PlaybackDiagnostics.info("cloudConnectivityProbe success spans=\(spans.count)")
            } catch {
                let category = CloudAdDetectionFailureCategory.classify(error)
                cloudProbeResult = "Failed · \(category.rawValue)"
                PlaybackDiagnostics.warning("cloudConnectivityProbe failed category=\(category.rawValue)")
            }
        }
    }
    #endif

    private var buildStampSection: some View {
        HStack {
            Text("Build")
            Spacer()
            Text(BuildStamp.bundled)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("buildStamp")
        .accessibilityLabel("Build")
        .accessibilityValue(BuildStamp.bundled)
    }

    // MARK: - Actions

    private func cycleCleaningAction() {
        store.defaultCleaningAction = store.defaultCleaningAction == .mute ? .skip : .mute
    }

    private func cycleMuteOverlayMode() {
        switch store.muteOverlayMode {
        case .off: store.muteOverlayMode = .beep
        case .beep: store.muteOverlayMode = .quack
        case .quack: store.muteOverlayMode = .off
        }
    }

    private func muteOverlayDisplayName(_ mode: MuteOverlayMode) -> String {
        switch mode {
        case .off: return "Off"
        case .beep: return "Beep"
        case .quack: return "Quack"
        }
    }

    private func cycleUnrelatedContentAction() {
        store.unrelatedContentAction = store.unrelatedContentAction == .skip ? .mute : .skip
    }

    private func cyclePlaybackRate() {
        let rates = PlaybackEngine.supportedRates
        let current = store.defaultPlaybackRate
        let index = rates.firstIndex(of: current) ?? rates.firstIndex(of: 1.0) ?? 0
        store.defaultPlaybackRate = rates[(index + 1) % rates.count]
    }

    private func addCustomWord() {
        store.addCustomWord(customWordDraft)
        customWordDraft = ""
    }

    private func categoryHint(for categoryID: String) -> String {
        switch categoryID {
        case "dWord": return "Includes or excludes D-word cleaning."
        case "fWord": return "Includes or excludes F-word cleaning."
        case "sWord": return "Includes or excludes S-word cleaning."
        case "racialSlurs": return "Includes or excludes racial slur cleaning."
        default: return "Includes or excludes this category."
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
