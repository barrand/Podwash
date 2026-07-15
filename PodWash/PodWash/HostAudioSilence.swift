//
//  HostAudioSilence.swift
//  PodWash
//
//  Silence episode/overlay players during automated verify so Mac speakers stay quiet.
//

import Foundation

/// Detects XCTest host, UITest app launches, or an explicit env override.
enum HostAudioSilence {
    static let environmentKey = "PODWASH_SILENCE_HOST_AUDIO"

    static var isEnabled: Bool {
        shouldSilence(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /// Pure seam for unit tests — pass synthetic env/args.
    static func shouldSilence(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment[environmentKey] == "1" {
            return true
        }
        // UITest app process has no XCTestConfigurationFilePath; fixtures use -UITest*.
        if arguments.contains(where: { $0.hasPrefix("-UITest") }) {
            return true
        }
        return false
    }
}
