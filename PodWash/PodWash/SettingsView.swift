//
//  SettingsView.swift
//  PodWash
//
//  Slice 13 — Settings screen (slice-13-settings-ux.md, ADR-010 §5).
//

import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    @State private var customWordDraft = ""
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
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
            Text("Unrelated content")
                .font(.headline)

            Toggle(isOn: $store.unrelatedContentEnabled) {
                Text("Skip unrelated content")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("unrelatedContentToggle")
            .accessibilityLabel("Skip unrelated content")
            .accessibilityValue(store.unrelatedContentEnabled ? "1" : "0")
            .accessibilityHint("Skips or mutes segments that seem unrelated to the story.")

            if store.unrelatedContentEnabled {
                Button(action: cycleUnrelatedContentAction) {
                    HStack {
                        Text("Unrelated content action")
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
                .accessibilityLabel("Unrelated content action")
                .accessibilityValue(store.unrelatedContentAction.rawValue)
                .accessibilityHint("Chooses skip or mute for unrelated segments.")
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
