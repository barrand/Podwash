//
//  HostAudioSilenceTests.swift
//  PodWashTests
//
//  Task-018 — silence detection covers XCTest, UITest launches, and env override.
//

import XCTest
@testable import PodWash

final class HostAudioSilenceTests: XCTestCase {

    func testShouldSilenceWhenXCTestConfigurationPresent() {
        XCTAssertTrue(
            HostAudioSilence.shouldSilence(
                environment: ["XCTestConfigurationFilePath": "/tmp/xctest"],
                arguments: []
            )
        )
    }

    func testShouldSilenceWhenUITestLaunchArgumentPresent() {
        XCTAssertTrue(
            HostAudioSilence.shouldSilence(
                environment: [:],
                arguments: ["-UITestFixtureAudio"]
            ),
            "UITest app process has no XCTestConfigurationFilePath; -UITest* must silence"
        )
        XCTAssertTrue(
            HostAudioSilence.shouldSilence(
                environment: [:],
                arguments: ["PodWash", "-UITestFixtureSkipOverride"]
            )
        )
    }

    func testShouldSilenceWhenEnvOverrideSet() {
        XCTAssertTrue(
            HostAudioSilence.shouldSilence(
                environment: [HostAudioSilence.environmentKey: "1"],
                arguments: []
            )
        )
    }

    func testShouldNotSilenceForNormalAppLaunch() {
        XCTAssertFalse(
            HostAudioSilence.shouldSilence(
                environment: [:],
                arguments: ["PodWash"]
            ),
            "Production launches must remain audible"
        )
        XCTAssertFalse(
            HostAudioSilence.shouldSilence(
                environment: [HostAudioSilence.environmentKey: "0"],
                arguments: []
            )
        )
    }
}
