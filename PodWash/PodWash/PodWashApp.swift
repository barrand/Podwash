//
//  PodWashApp.swift
//  PodWash
//
//  Created by Bryce Barrand on 7/8/26.
//

import SwiftUI

@main
struct PodWashApp: App {
    private let persistence = PersistenceController.production()

    var body: some Scene {
        WindowGroup {
            RootView(persistence: persistence)
        }
    }
}
