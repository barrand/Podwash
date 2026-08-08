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
        guard FirebaseApp.app() != nil else { throw CloudAdDetectionError.firebaseNotConfigured }
        let user: FirebaseAuth.User
        do {
            if let current = Auth.auth().currentUser {
                user = current
            } else {
                user = try await Auth.auth().signInAnonymously().user
            }
        } catch {
            throw CloudAdDetectionError.firebaseAuth
        }
        async let appCheck = appCheckToken()
        async let idToken = idToken(for: user)
        return [
            "X-Firebase-AppCheck": try await appCheck,
            "Authorization": "Bearer \(try await idToken)",
        ]
    }

    private func appCheckToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            AppCheck.appCheck().token(forcingRefresh: false) { token, error in
                if error != nil { continuation.resume(throwing: CloudAdDetectionError.appCheck) }
                else if let token { continuation.resume(returning: token.token) }
                else { continuation.resume(throwing: CloudAdDetectionError.appCheck) }
            }
        }
    }

    private func idToken(for user: FirebaseAuth.User) async throws -> String {
        do {
            return try await user.getIDToken()
        } catch {
            throw CloudAdDetectionError.firebaseAuth
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

/// Firebase supplies the App Attest provider, while the app supplies the
/// factory that vends it before Firebase is configured.
private final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
