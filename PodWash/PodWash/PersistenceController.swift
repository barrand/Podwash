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
    /// `nonisolated`: app `@main` / test-host bootstrap may construct this before the
    /// main-actor executor is fully established; keep it off the default MainActor.
    nonisolated static func production() -> PersistenceController {
        makeController(
            storeURL: applicationSupportStoreURL(),
            wal: false,
            fatalPrefix: "Unresolved Core Data error"
        )
    }

    /// Isolated store for unit tests.
    /// Temp-directory SQLite URL keyed by `identifier` so a second controller reloads
    /// the same durable state (ADR-009 §3 reload pattern — temp SQLite variant).
    nonisolated static func inMemory(identifier: String = UUID().uuidString) -> PersistenceController {
        let controller = makeController(
            storeURL: temporaryStoreURL(identifier: identifier),
            wal: true,
            fatalPrefix: "Unresolved test Core Data error"
        )
        controller.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return controller
    }

    /// Shared NSPersistentContainer wiring for production + test stores (queue/resume model).
    nonisolated private static func makeController(
        storeURL: URL,
        wal: Bool,
        fatalPrefix: String
    ) -> PersistenceController {
        let container = NSPersistentContainer(name: "PodWash")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        if wal {
            // WAL lets a second controller open the same file while the first is still alive.
            description.setOption(
                ["journal_mode": "WAL"] as NSDictionary,
                forKey: NSSQLitePragmasOption
            )
        }
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("\(fatalPrefix): \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
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
