//
//  MuteOverlayMode.swift
//  PodWash
//
//  Slice 16 — Mute overlay mode (ADR-017).
//

import Foundation

/// User-selectable sound during mute intervals (silent-first default).
enum MuteOverlayMode: String, Codable, Equatable, Sendable {
    case off
    case beep
    case quack

    /// Stable asset ID for event recording / tests (ADR-017 §3).
    var assetID: String? {
        switch self {
        case .off: return nil
        case .beep: return "beep"
        case .quack: return "quack"
        }
    }

    /// Bundle resource name (without extension).
    var resourceName: String? {
        assetID
    }
}
