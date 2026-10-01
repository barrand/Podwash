import XCTest
@testable import PodWash

@MainActor final class EpisodeDownloadAffordanceTests: XCTestCase {
    func testNotDownloadedOffersDownloadNotDelete() {
        let row = EpisodeRowPresentationMapper.map(.notDownloaded)
        XCTAssertEqual(row.primaryControl, .download)
        XCTAssertEqual(row.symbolName, "arrow.down.circle")
        XCTAssertNotEqual(row.tint, .danger)
    }
    func testDownloadedNotPreparedOffersPrepare() {
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.downloadedNotPrepared).primaryControl, .prepare)
    }
    func testReadyOffersPlayAndRemovalOnlyInMenu() {
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.readyOffline).primaryControl, .play)
        let facts = EpisodeMenuFacts(isQueued: false, isPlayed: false, hasLocalAudio: true,
            hasExplicitOwner: false, hasTranscript: false, hasLocalCleaning: true, readiness: .readyOffline)
        XCTAssertTrue(EpisodeMenuPolicy.actions(facts).contains(.removeDownload))
    }
    func testNonFiniteDownloadProgressIsIndeterminate() {
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.downloading(progress: .nan)).primaryControl, .progress(nil))
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.downloading(progress: .infinity)).primaryControl, .progress(nil))
    }
    func testQueuedMenuIncludesBothMoveAndRemove() {
        let facts = EpisodeMenuFacts(isQueued: true, isPlayed: false, hasLocalAudio: false,
            hasExplicitOwner: false, hasTranscript: false, hasLocalCleaning: false, readiness: .notDownloaded)
        let actions = EpisodeMenuPolicy.actions(facts)
        XCTAssertTrue(actions.contains(.moveToTop))
        XCTAssertTrue(actions.contains(.removeFromUpNext))
        XCTAssertFalse(actions.contains(.addToUpNext))
        XCTAssertFalse(actions.contains(.cancelPreparation))
    }

    func testDelayedCloudRecoveryRequiresCompletedLocalProcessing() {
        let complete = EpisodeMenuFacts(isQueued: true, isPlayed: false, hasLocalAudio: true,
            hasExplicitOwner: true, hasTranscript: true, hasLocalCleaning: true,
            readiness: .adCheckDelayed(retryAt: nil), cloudFailure: .network)
        XCTAssertEqual(EpisodeMenuPolicy.actions(complete), [.moveToTop, .removeFromUpNext,
            .cancelPreparation, .retry, .playWithoutAdSkipping, .transcript, .markPlayed, .removeDownload])
        let incomplete = EpisodeMenuFacts(isQueued: false, isPlayed: false, hasLocalAudio: true,
            hasExplicitOwner: true, hasTranscript: true, hasLocalCleaning: false,
            readiness: .adCheckDelayed(retryAt: nil), cloudFailure: .network)
        XCTAssertFalse(EpisodeMenuPolicy.actions(incomplete).contains(.playWithoutAdSkipping))
        XCTAssertFalse(EpisodeMenuPolicy.actions(incomplete).contains(.playOriginalAudio))
    }

    func testCurrentAudioIsProtectedAndGenericFailureOnlyOffersOriginalAudio() {
        let facts = EpisodeMenuFacts(isQueued: false, isPlayed: true, hasLocalAudio: true,
            hasExplicitOwner: true, hasTranscript: true, hasLocalCleaning: false,
            readiness: .needsAttention(detail: "Local preparation failed"), protectsLocalAudio: true)
        XCTAssertEqual(EpisodeMenuPolicy.actions(facts), [.addToUpNext, .playOriginalAudio, .transcript, .replay])
    }
}
