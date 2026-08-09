# PodWash App Store release readiness

Use this checklist for the first App Store submission. Complete items in order;
record the owner, date, and evidence beside each check when it is done.

## 1. Release source and build

- [x] **1.1** Identify a clean, reviewed release commit. Do not archive while
  unrelated local changes are present. Current candidate: `3be5fe7` on `main`.
- [x] **1.2** Set the intended marketing version and increment the build number
  from `1`. Release candidate: version `1.0`, build `2`.
- [x] **1.3** Confirm the Distribution signing certificate, provisioning profile, bundle ID,
  and Release entitlements are correct for `com.barrandfarm.PodWash`. Completed
  2026-08-08: App Store validation succeeded with the paid team, matching bundle
  ID, production App Attest entitlement, and Firebase configuration.
- [x] **1.4** Run `scripts/release-verify.sh` from the clean release commit, retain its
  `build/test-results/latest.md` evidence, then Archive and Validate the Release build.
  Completed 2026-08-09: release verification passed 79/79 with zero skips or retries
  (`verify-20260809-090316-93976`, 1233s) at `3a19cd1`; Organizer validated the
  `1.0 (3)` Release archive successfully.
- [ ] **1.5** Install the archive on a physical iPhone and test fresh install, playback,
  downloads, background audio, transcript follow, and offline behavior.
- [ ] **1.6** Test real-world interruptions: lock screen and Control Center controls,
  headphones, incoming calls, route changes, background/resume, low storage, and
  loss/recovery of network connectivity.
- [ ] **1.7** Test accessibility in the Release build: VoiceOver labels and order, Dynamic
  Type, contrast, and transcript controls including follow/recenter.
- [ ] **1.8** Review the iOS 26.1 deployment target and confirm that device/OS coverage is
  intentional.

## 2. Production cloud service

- [ ] **2.1** Add the production `GoogleService-Info.plist` to the archive target through
  a secure, non-repository delivery process.
- [ ] **2.2** Verify Firebase Anonymous Auth, production App Attest, and Cloud Run work in
  a Release/TestFlight build. Confirm App Check enforcement and backend quotas,
  alerts, and kill switch are live.
- [ ] **2.3** Verify consent copy and behavior: cloud ad detection sends transcript text,
  never audio; opt-out remains functional.
  - [ ] Implement a first-use, explicit opt-in before any timed transcript text is
    shared with Gemini or another cloud provider. The disclosure must identify the
    third-party AI service, state that audio is not uploaded, and offer a clear
    decline path.
  - [ ] Test that declining consent sends no transcript text, that core playback
    remains available, and that withdrawing consent in Settings stops all future
    cloud submissions.
- [ ] **2.4** Confirm production error reporting, dashboards, alerts, and an owner for
  responding to service failures after launch.
- [ ] **2.5** Remove or confirm exclusion of all debug-only diagnostics and connectivity
  probes from the release archive.

## 3. Privacy, legal, and compliance

- [ ] **3.1** Publish a privacy policy and support page with current contact details.
- [ ] **3.2** Add an easy-to-find in-app Privacy Policy link.
- [ ] **3.3** Complete App Store Connect App Privacy responses for PodWash and third-party
  services (Firebase, Cloud Run, Gemini), including transcript handling,
  anonymous installation identity, retention, consent withdrawal, and deletion.
  - [ ] Validate every response against the final app build and actual provider
    configuration, including Firebase Authentication/App Check, Cloud Run/Firestore
    logs, Gemini data-use settings, and support email.
- [ ] **3.4** Document the user data-deletion/contact process in the privacy policy and
  verify that the support contact can fulfill it.
  - [ ] Define and test how a request can identify, delete, or explain the limits
    of deletion for anonymous Firebase accounts, cloud records, provider logs, and
    locally stored data.
- [ ] **3.5** Run Xcode's privacy report and add/update an app privacy manifest if it
  identifies required-reason API declarations for PodWash code.
- [ ] **3.6** Complete export-compliance questions for the release build; retain the
  decision/evidence used for the answers.
- [ ] **3.7** Confirm rights and terms for podcast discovery, streaming, and downloads.

## 4. App Store Connect and review

- [ ] **4.1** Create the app record for bundle ID `com.barrandfarm.PodWash` (if absent).
- [ ] **4.2** Confirm Apple Developer Program membership and App Store Connect agreements,
  tax, and banking details are active if the app will be paid or offer purchases.
- [ ] **4.3** Provide name, subtitle, description, keywords, category, age rating,
  pricing/availability, copyright, icon, and device screenshots.
  - [ ] Finalize the fields in `docs/app-store-listing.md`, including legal developer
    name, category, price, availability, age rating, and App Review notes.
  - [ ] Prepare a stable release-build screenshot-capture flow with approved content;
    capture the planned set on required iPhone and iPad device sizes after the final
    Release/TestFlight build is available.
- [ ] **4.4** Review the product page on each required device size; screenshots and copy
  must accurately reflect the shipped experience and any optional cloud feature.
- [ ] **4.5** Add the Privacy Policy URL and Support URL in App Store Connect.
- [ ] **4.6** Upload the validated build; complete export compliance and TestFlight smoke
  testing.
- [ ] **4.7** Distribute through TestFlight (at least internal testing; external testing if
  useful), review feedback/crashes, and re-test the final candidate build.
- [ ] **4.8** Write App Review notes: no account is required; cloud ad detection is
  optional and sends transcript text only; include any reviewer steps needed to
  exercise it. If any app path requires credentials, provide a working demo
  account and keep it available through review.
- [ ] **4.9** Select a release method, submit, and monitor App Review messages.

## 5. Launch ownership

- [ ] **5.1** Prepare a support response path and a lightweight process for handling App
  Review questions, user reports, and privacy requests.
- [ ] **5.2** Record the released version, build number, archive location, signing owner,
  production-service owner, and rollback/kill-switch steps in the release notes.
- [ ] **5.3** After release, monitor crashes, backend health, App Review messages, and
  early support reports; decide whether to pause phased release or ship a fix.

## Current state (2026-08-08)

- `main` includes the transcript follow-along (`a51b06a`) and queue redesign
  (`82e86c5`) work intended for the 1.0 release.
- Release-source prerequisite **1.1** is complete at release commit `3be5fe7`.
- Release version prerequisite **1.2** is complete: `1.0 (2)`.
- Signing prerequisite **1.3** is complete: App Store validation succeeded. The
  archive's signed entitlements include production App Attest and the matching
  Firebase configuration.
- Release verification prerequisite **1.4** is complete: build `1.0 (3)` passed the
  release verification gate and Organizer validation on 2026-08-09.
- The repository intentionally omits `GoogleService-Info.plist`; a production
  archive must supply it by a secure delivery process.
- The project currently uses marketing version `1.0`, build `3`, and an iOS 26.1
  deployment target.
