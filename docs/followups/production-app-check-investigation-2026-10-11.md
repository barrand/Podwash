# Production App Check investigation — 2026-10-11

## Symptom

In the production iOS app, episode preparation reaches **Ad check failed** with
the diagnostic category `PW-PREP-CLOUD-APP-CHECK`. Re-downloading an episode
and force-quitting/relaunching the app did not resolve it.

Relevant on-device diagnostics show the failure happens immediately after cloud
ad detection starts:

```
cloudAdDetection start …
cloudAdDetection failed … category=appCheck
```

Observed latency was roughly 170–380 ms. That is before a request can reach
the Cloud Run gateway, so this is a local Firebase App Check token-generation
failure—not an episode-download, transcript, Jev, Firestore, or Cloud Run
pipeline failure.

## Confirmed production configuration

Firebase project settings were inspected in the Firebase console:

- Project name: `PodWash`
- Project ID: `gen-lang-client-0583348292`
- Project number: `155728924073`
- The Cloud Run endpoint in the app uses that same project number:
  `https://podwash-jev-155728924073.us-central1.run.app`
- iOS Firebase app: `com.barrandfarm.PodWash`
- Firebase App Check is registered for that app with **App Attest**.
- App Attest Team ID: `TW8PRJC365`.
- The Xcode target uses the same development team and contains the production
  App Attest entitlement.
- Firebase Authentication’s **Anonymous** provider is enabled.

The Release build is not compiled with `DEBUG`; it uses the App Attest provider
instead of Firebase's debug provider. The App Attest production wiring was
present before the release build (`3be5fe7`).

## Code path

`FirebaseCloudCredentials.authorizationHeaders()` gets an anonymous-auth ID
token and an App Check token concurrently. `appCheckToken()` maps every
underlying Firebase error to the generic `.appCheck` category:

```swift
AppCheck.appCheck().token(forcingRefresh: false) { token, error in
    if error != nil { continuation.resume(throwing: CloudAdDetectionError.appCheck) }
    else if let token { continuation.resume(returning: token.token) }
    else { continuation.resume(throwing: CloudAdDetectionError.appCheck) }
}
```

That mapping is intentional for listener-safe UI but discards the exact Firebase
error domain and numeric code needed to identify the failing App Attest step.

Relevant files:

- `PodWash/PodWash/FirebaseCloudCredentials.swift`
- `PodWash/PodWash/CloudAdSpanClient.swift`
- `PodWash/PodWash/PodWash.entitlements`

## What was not useful / ruled out

- Re-downloading an episode does not reset Firebase/App Check state.
- The app’s verbose playback diagnostics include media URLs but those are
  unrelated to this token failure and should not be copied into tickets/logs.
- Cloud Run is reachable, but this error happens before the app sends an HTTP
  request.
- Firebase Crashlytics currently reports that it is waiting for its first crash;
  this handled failure does not produce a crash report.

## Next steps on a Mac

1. Connect the affected iPhone to Xcode and open **Devices and Simulators** →
   **Open Console** (or use the Xcode debug console while running PodWash).
2. Filter for `PodWash`, `FirebaseAppCheck`, `AppCheck`, and `AppAttest`.
3. In PodWash, run **Settings → Test cloud ad detection** once.
4. Capture the Firebase/App Attest error domain and numeric code, plus the
   immediately adjacent log line. Do not capture tokens, authorization headers,
   transcripts, or media URLs.
5. If no useful SDK line is emitted, add a privacy-safe diagnostic that records
   only the underlying `NSError.domain` and `NSError.code` before mapping to
   `CloudAdDetectionError.appCheck`. Ship it in a TestFlight build, then retry.

Likely outcomes once the underlying code is known: App Attest availability/key
generation issue on the device, a signed-entitlements/provisioning mismatch in
the distributed archive, or a Firebase token-exchange/registration issue.
