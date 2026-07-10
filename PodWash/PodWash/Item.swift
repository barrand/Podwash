//
//  Item.swift
//  PodWash
//
//  Minimal app-module type retained for Slice 01 SmokeTests (`testAppModuleLoads`).
//  SwiftData `ModelContainer` wiring was removed in Slice 11 (ADR-007); this is a
//  plain value holder, not a persistence model.
//

import Foundation

struct Item {
    var timestamp: Date
}
