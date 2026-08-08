# PodWash App Store release readiness

Use this checklist for the first App Store submission. Complete items in order;
record the owner, date, and evidence beside each check when it is done.

## 1. Release source and build

- [ ] Archive from a clean, reviewed release commit. Do not archive while unrelated
  local changes are present.
- [ ] Set the intended marketing version and increment the build number from `1`.
- [ ] Run the full verification suite, then Archive and Validate the Release build.
- [ ] Install the archive on a physical iPhone and test fresh install, playback,
  downloads, background audio, transcript follow, and offline behavior.
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
- [ ] Remove or confirm exclusion of all debug-only diagnostics and connectivity
  probes from the release archive.

## 3. Privacy, legal, and compliance

- [ ] Publish a privacy policy and support page with current contact details.
- [ ] Add an easy-to-find in-app Privacy Policy link.
- [ ] Complete App Store Connect App Privacy responses for PodWash and third-party
  services (Firebase, Cloud Run, Gemini), including transcript handling,
  anonymous installation identity, retention, consent withdrawal, and deletion.
- [ ] Run Xcode's privacy report and add/update an app privacy manifest if it
  identifies required-reason API declarations for PodWash code.
- [ ] Complete export-compliance questions for the release build; retain the
  decision/evidence used for the answers.
- [ ] Confirm rights and terms for podcast discovery, streaming, and downloads.

## 4. App Store Connect and review

- [ ] Create the app record for bundle ID `com.barrandfarm.PodWash` (if absent).
- [ ] Provide name, subtitle, description, keywords, category, age rating,
  pricing/availability, icon, and device screenshots.
- [ ] Add the Privacy Policy URL and Support URL in App Store Connect.
- [ ] Upload the validated build; complete export compliance and TestFlight smoke
  testing.
- [ ] Write App Review notes: no account is required; cloud ad detection is
  optional and sends transcript text only; include any reviewer steps needed to
  exercise it.
- [ ] Select a release method, submit, and monitor App Review messages.

## Current state (2026-08-08)

- `main` contains transcript follow-along commit `a51b06a`.
- The queue redesign is intended for the 1.0 release. It must be committed and
  included in the release verification before creating an archive.
- The repository intentionally omits `GoogleService-Info.plist`; a production
  archive must supply it by a secure delivery process.
- The project currently uses marketing version `1.0`, build `1`, and an iOS 26.1
  deployment target.
