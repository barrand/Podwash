# To-do

- Implement the frozen Jev V7.1 backend and schema-v2 typed segment contract in
  `docs/plans/jev-mvp.md`, including budgets, processing leases, and fixture
  parity tests.
- Implement canonical typed-segment storage and local Obvious/More/Most preset
  projection; invalidate all old untyped Gemini analysis artifacts.
- Add the Settings preset picker: Skip obvious by default, with functional Skip
  more and Skip most choices clearly marked Experimental.
- Deploy and verify the new Jev-only Cloud Run service in TestFlight, then remove
  Gemini production code, dependency, key, endpoint, service, and current
  privacy/deployment wording before App Store submission.
- Complete the Jev MVP release gates: backend/iOS/UI suites, physical-device ad
  playback, consent and failure paths, kill switch, privacy answers, monitoring,
  archive validation, and App Store review notes.
- Investigate the production "Preparation needs attention" error seen yesterday; verify whether server-side changes were deployed before the app supported them.
- When preparation needs attention, expose actionable error details and a way for the user to resolve or retry it.
- Improve the played-episode card: make its played state prominent, and hide or de-emphasize the offline "Ready to play" label when the episode has already been played (the play button remains the replay action).
- Build a home-screen display widget.

## Done

- Add analytics.
