//
//  BuildStamp.swift
//  PodWash
//
//  Task 008 — compile-time build stamp (Mountain Time, YY.M.D.H.MM.SS).
//

import Foundation

enum BuildStamp {
    private static let mountainTime = TimeZone(identifier: "America/Denver")!
    private static let infoPlistKey = "PodWashBuildStamp"

    /// Stamp baked into this binary at build/link time (Info.plist key injected by build phase).
    static var bundled: String {
        Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String ?? ""
    }

    /// Formats `date` in America/Denver as `YY.M.D.H.MM.SS` (unpadded M/D/H; MM/SS zero-padded).
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mountainTime
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let yy = (parts.year ?? 0) % 100
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        return String(format: "%d.%d.%d.%d.%02d.%02d", yy, month, day, hour, minute, second)
    }
}
