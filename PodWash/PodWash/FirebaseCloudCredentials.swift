//
//  FirebaseCloudCredentials.swift
//  PodWash
//

import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation

/// Anonymous Auth + App Check credentials for the Cloud Run gateway. Neither
/// credential identifies the listener to PodWash; the UID is only a stable
/// installation identity for abuse protection and future server-side caps.
final class FirebaseCloudCredentials: CloudCredentialProviding, @unchecked Sendable {
    func authorizationHeaders() async throws -> [String: String] {
        let user: FirebaseAuth.User
        if let current = Auth.auth().currentUser {
            user = current
        } else {
            user = try await Auth.auth().signInAnonymously().user
        }
        async let appCheck = appCheckToken()
        async let idToken = user.getIDToken()
        return [
            "X-Firebase-AppCheck": try await appCheck,
            "Authorization": "Bearer \(try await idToken)",
        ]
    }

    private func appCheckToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            AppCheck.appCheck().token(forcingRefresh: false) { token, error in
                if let error { continuation.resume(throwing: error) }
                else if let token { continuation.resume(returning: token.token) }
                else { continuation.resume(throwing: CloudAdDetectionError.unavailable) }
            }
        }
    }
}

enum FirebaseCloudBootstrap {
    static func configure() {
        guard FirebaseApp.app() == nil else { return }
        // The repository cannot contain the project-specific GoogleService-Info.plist.
        // Until deployment supplies it, cloud ad detection remains unavailable rather
        // than preventing the rest of the offline app from launching.
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif
        FirebaseApp.configure()
    }
}
