//
//  AppTiming.swift
//  PodWash
//

import Foundation

/// Small clock boundary shared by refresh and preparation work.  Tests can
/// advance a logical clock instead of waiting for network or retry delays.
protocol AppTiming: Sendable {
    func now() async -> Date
    func sleep(for interval: TimeInterval) async throws
}

struct SystemAppTiming: AppTiming {
    func now() async -> Date { Date() }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}
