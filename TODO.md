# To-do

- Deploy and verify the new Jev-only Cloud Run service in TestFlight, then remove
  the old deployed Gemini key and service after the smoke test passes.
- Complete the Jev MVP release gates: backend/iOS/UI suites, physical-device ad
  playback, consent and failure paths, kill switch, privacy answers, monitoring,
  archive validation, and App Store review notes.
- Investigate the production "Preparation needs attention" error seen yesterday; verify whether server-side changes were deployed before the app supported them.
- Implement the [preparation failure recovery plan](docs/plans/preparation-failure-recovery.md): expose actionable details and safe retry or original-audio recovery.
- Improve the played-episode card: make its played state prominent, and hide or de-emphasize the offline "Ready to play" label when the episode has already been played (the play button remains the replay action).
- Build a home-screen display widget.

## Done

- Implement the frozen Jev V7.1 backend and schema-v2 typed segment contract,
  including request budgets, processing leases, retries, and frozen policy
  tests.
- Implement canonical typed-segment storage and local Obvious/More/Most preset
  projection; invalidate old untyped analysis artifacts.
- Add the Settings preset picker: Skip obvious by default, with functional Skip
  more and Skip most choices clearly marked Experimental.
- Remove Gemini from the production app/backend code, dependencies, endpoint,
  cache identity, and current privacy/deployment wording.
- Add analytics.
