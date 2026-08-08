# PodWash App Store release readiness

Use this checklist for the first App Store submission. Complete items in order;
record the owner, date, and evidence beside each check when it is done.

## 1. Release source and build

- [ ] Archive from a clean, reviewed release commit. Do not archive while unrelated
  local changes are present.
- [ ] Set the intended marketing version and increment the build number from `1`.
- [ ] Confirm the Distribution signing certificate, provisioning profile, bundle ID,
  and Release entitlements are correct for `com.barrandfarm.PodWash`.
- [ ] Run the full verification suite, then Archive and Validate the Release build.
- [ ] Install the archive on a physical iPhone and test fresh install, playback,
  downloads, background audio, transcript follow, and offline behavior.
- [ ] Test real-world interruptions: lock screen and Control Center controls,
  headphones, incoming calls, route changes, background/resume, low storage, and
  loss/recovery of network connectivity.
- [ ] Test accessibility in the Release build: VoiceOver labels and order, Dynamic
  Type, contrast, and transcript controls including follow/recenter.
- [ ] Review the iOS 26.1 deployment target and confirm that device/OS coverage is
  intentional.

## 2. Production cloud service

- [ ] Add the production `GoogleService-Info.plist` to the archive target through
  a secure, non-repository delivery process.
- [ ] Verify Firebase Anonymous Auth, production App Attest, and Cloud Run work in
  a Release/TestFlight build. Confirm App Check enforcement and backend quotas,
  alerts, and kill switch are live.
- [ ] Verify consent copy and behavior: cloud ad detection sends transcript text,
  never audio; opt-out remains functional.
- [ ] Confirm production error reporting, dashboards, alerts, and an owner for
  responding to service failures after launch.
- [ ] Remove or confirm exclusion of all debug-only diagnostics and connectivity
  probes from the release archive.

## 3. Privacy, legal, and compliance

- [ ] Publish a privacy policy and support page with current contact details.
- [ ] Add an easy-to-find in-app Privacy Policy link.
- [ ] Complete App Store Connect App Privacy responses for PodWash and third-party
  services (Firebase, Cloud Run, Gemini), including transcript handling,
  anonymous installation identity, retention, consent withdrawal, and deletion.
- [ ] Document the user data-deletion/contact process in the privacy policy and
  verify that the support contact can fulfill it.
- [ ] Run Xcode's privacy report and add/update an app privacy manifest if it
  identifies required-reason API declarations for PodWash code.
- [ ] Complete export-compliance questions for the release build; retain the
  decision/evidence used for the answers.
- [ ] Confirm rights and terms for podcast discovery, streaming, and downloads.

## 4. App Store Connect and review

- [ ] Create the app record for bundle ID `com.barrandfarm.PodWash` (if absent).
- [ ] Confirm Apple Developer Program membership and App Store Connect agreements,
  tax, and banking details are active if the app will be paid or offer purchases.
- [ ] Provide name, subtitle, description, keywords, category, age rating,
  pricing/availability, copyright, icon, and device screenshots.
- [ ] Review the product page on each required device size; screenshots and copy
  must accurately reflect the shipped experience and any optional cloud feature.
- [ ] Add the Privacy Policy URL and Support URL in App Store Connect.
- [ ] Upload the validated build; complete export compliance and TestFlight smoke
  testing.
- [ ] Distribute through TestFlight (at least internal testing; external testing if
  useful), review feedback/crashes, and re-test the final candidate build.
- [ ] Write App Review notes: no account is required; cloud ad detection is
  optional and sends transcript text only; include any reviewer steps needed to
  exercise it. If any app path requires credentials, provide a working demo
  account and keep it available through review.
- [ ] Select a release method, submit, and monitor App Review messages.

## 5. Launch ownership

- [ ] Prepare a support response path and a lightweight process for handling App
  Review questions, user reports, and privacy requests.
- [ ] Record the released version, build number, archive location, signing owner,
  production-service owner, and rollback/kill-switch steps in the release notes.
- [ ] After release, monitor crashes, backend health, App Review messages, and
  early support reports; decide whether to pause phased release or ship a fix.

## Current state (2026-08-08)

- `main` contains transcript follow-along commit `a51b06a`.
- The queue redesign is intended for the 1.0 release. It must be committed and
  included in the release verification before creating an archive.
- The repository intentionally omits `GoogleService-Info.plist`; a production
  archive must supply it by a secure delivery process.
- The project currently uses marketing version `1.0`, build `1`, and an iOS 26.1
  deployment target.
