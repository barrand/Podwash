//
//  PersistenceController.swift
//  PodWash
//
//  Slice 11 — NSPersistentContainer factory (ADR-007, ADR-009 §3).
//

import CoreData
import Foundation

/// Container factory. Opted out of module default MainActor isolation so stores and
/// test helpers can construct controllers synchronously from nonisolated contexts.
nonisolated final class PersistenceController: @unchecked Sendable {
    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    private init(container: NSPersistentContainer) {
        self.container = container
    }

    /// On-disk store under Application Support (`PodWash.sqlite`).
    static func production() -> PersistenceController {
        let container = NSPersistentContainer(name: "PodWash")
        let storeURL = applicationSupportStoreURL()
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved Core Data error: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return PersistenceController(container: container)
    }

    /// Isolated store for unit tests.
    /// Temp-directory SQLite URL keyed by `identifier` so a second controller reloads
    /// the same durable state (ADR-009 §3 reload pattern — temp SQLite variant).
    static func inMemory(identifier: String = UUID().uuidString) -> PersistenceController {
        let container = NSPersistentContainer(name: "PodWash")
        let storeURL = temporaryStoreURL(identifier: identifier)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        // WAL lets a second controller open the same file while the first is still alive.
        description.setOption(
            ["journal_mode": "WAL"] as NSDictionary,
            forKey: NSSQLitePragmasOption
        )
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved test Core Data error: \(error)")
            }
        }
        let context = container.viewContext
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return PersistenceController(container: container)
    }

    func save() throws {
        let context = viewContext
        guard context.hasChanges else { return }
        try context.performAndWait {
            try context.save()
        }
    }

    private static func applicationSupportStoreURL() -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = folder.appendingPathComponent("PodWash", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PodWash.sqlite")
    }

    private static func temporaryStoreURL(identifier: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodWash-test-\(identifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.sqlite")
    }
}
