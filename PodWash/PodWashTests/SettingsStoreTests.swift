//
//  SettingsStoreTests.swift
//  PodWashTests
//
//  Slice 13 — Settings + word-list management (ADR-010). AC1–AC4.
//
//  Fixture provenance:
//  - Isolated UserDefaults suite per test (ADR-010 §6) — no cross-test leakage.
//  - Custom-word token "xyzzy!" → "xyzzy" per matching-spec §3 (hand-derived from
//    normalize rules; independent of SettingsStore implementation).
//  - Default profile categories pinned in slice AC1 / WordCategories.defaultEnabledIDs.
//  - sWord disable count delta of 4 from slice seed list (spec §7 S-word subset).
//
//  Until SettingsStore, SettingsCleaningAction, and WordCategories exist (Engineer,
//  later effort), this file fails to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class SettingsStoreTests: XCTestCase {

    private var userDefaults: UserDefaults!
    private var suiteName: String!

    private let rateTolerance: Float = 0.001

    override func setUp() {
        super.setUp()
        suiteName = "podwash.settings.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        userDefaults = defaults
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(userDefaults: userDefaults)
    }

    // MARK: - AC1: fresh store matches PRD default profile

    func testFreshStoreMatchesPRDDefaultProfile() {
        let store = makeStore()

        XCTAssertEqual(
            Set(store.enabledCategoryIDs),
            WordCategories.defaultEnabledIDs,
            "Exactly four categories must be ON by default"
        )
        XCTAssertEqual(store.enabledCategoryIDs.count, 4)

        for categoryID in WordCategories.allIDs {
            let expectedEnabled = WordCategories.defaultEnabledIDs.contains(categoryID)
            XCTAssertEqual(
                store.isCategoryEnabled(categoryID),
                expectedEnabled,
                "Category \(categoryID) enabled state must match PRD default profile"
            )
        }

        XCTAssertFalse(store.isCategoryEnabled("godsName"))
        XCTAssertFalse(store.isCategoryEnabled("otherProfanity"))

        XCTAssertEqual(store.defaultCleaningAction, .mute)
        XCTAssertEqual(store.defaultPlaybackRate, 1.0, accuracy: rateTolerance)
        XCTAssertFalse(store.autoDownloadEnabled)
        XCTAssertFalse(store.autoDeleteAfterPlayedEnabled)
        XCTAssertTrue(store.customWords.isEmpty)
    }

    // MARK: - AC2: category toggle updates composed target set

    func testCategoryToggleUpdatesTargetSet() {
        let store = makeStore()
        let targetSet = { store.activeNormalizedTargetSet() }

        XCTAssertTrue(
            WordMatcher.matches("shit", in: targetSet()),
            "Default profile must include sWord seeds"
        )
        XCTAssertTrue(
            WordMatcher.matches("fuck", in: targetSet()),
            "Default profile must include fWord seeds"
        )

        let countBefore = targetSet().count
        store.setCategoryEnabled("sWord", false)

        XCTAssertFalse(
            WordMatcher.matches("shit", in: targetSet()),
            "Disabling sWord must remove shit from the active target set"
        )
        XCTAssertTrue(
            WordMatcher.matches("fuck", in: targetSet()),
            "Disabling sWord must not remove fWord seeds"
        )
        XCTAssertEqual(
            countBefore - targetSet().count,
            4,
            "Disabling sWord must drop exactly four normalized tokens"
        )

        let countAfterDisable = targetSet().count

        let reloaded = SettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(WordMatcher.matches("shit", in: reloaded.activeNormalizedTargetSet()))
        XCTAssertEqual(
            reloaded.activeNormalizedTargetSet().count,
            countAfterDisable,
            "Reloaded store must retain disabled category state"
        )

        store.setCategoryEnabled("sWord", true)
        XCTAssertTrue(
            WordMatcher.matches("shit", in: targetSet()),
            "Re-enabling sWord must restore shit membership"
        )
    }

    // MARK: - AC3: custom word add/remove lifecycle

    func testCustomWordLifecycle() {
        let store = makeStore()

        store.addCustomWord("  xyzzy!  ")
        XCTAssertTrue(
            store.activeNormalizedTargetSet().contains("xyzzy"),
            "addCustomWord must normalize per matching-spec §3"
        )

        store.removeCustomWord("xyzzy")
        XCTAssertFalse(
            store.activeNormalizedTargetSet().contains("xyzzy"),
            "removeCustomWord must drop the normalized token"
        )

        let reloadedAfterRemove = SettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(
            reloadedAfterRemove.activeNormalizedTargetSet().contains("xyzzy"),
            "Removed custom word must stay removed after reload"
        )

        reloadedAfterRemove.addCustomWord("xyzzy!")
        XCTAssertTrue(
            reloadedAfterRemove.activeNormalizedTargetSet().contains("xyzzy"),
            "Re-added custom word must persist as normalized xyzzy"
        )

        let reloadedAfterAdd = SettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(
            reloadedAfterAdd.activeNormalizedTargetSet().contains("xyzzy"),
            "Re-added custom word must survive a second reload"
        )
    }

    // MARK: - AC4: playback/cleaning defaults persist across reload

    func testDefaultsPersist() {
        let store = makeStore()

        store.defaultCleaningAction = .skip
        store.defaultPlaybackRate = 2.0
        store.autoDownloadEnabled = true
        store.autoDeleteAfterPlayedEnabled = true

        let reloaded = SettingsStore(userDefaults: userDefaults)

        XCTAssertEqual(reloaded.defaultCleaningAction, .skip)
        XCTAssertEqual(reloaded.defaultPlaybackRate, 2.0, accuracy: rateTolerance)
        XCTAssertTrue(reloaded.autoDownloadEnabled)
        XCTAssertTrue(reloaded.autoDeleteAfterPlayedEnabled)
    }
}
