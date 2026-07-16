//
//  CDNowPlayingSession.swift
//  PodWash
//
//  Slice 31 — Manual Core Data subclass for the durable active-session singleton
//  (ADR-027 §1). Hand-authored so compile does not depend on Xcode's incremental
//  `codeGenerationType=class` DerivedSources (forge builds were deleting those as
//  stale and failing with "cannot find type 'CDNowPlayingSession' in scope").
//

import CoreData
import Foundation

@objc(CDNowPlayingSession)
public class CDNowPlayingSession: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDNowPlayingSession> {
        NSFetchRequest<CDNowPlayingSession>(entityName: "CDNowPlayingSession")
    }

    @NSManaged public var activeEpisodeID: String?
}
