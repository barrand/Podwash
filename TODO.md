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
- It doesn't appear to be deleting played episodes. I still see them hanging round. something odd in the file management
- I got one episode to prepare clean playback, but nothing else is coming up in the queue. It seems like it should be queuing up more for the future. I don't think this part is working. Maybe it is in the deep cuts in other podcast lists but I don't see it happening. Maybe in the queue list it should show what is being prepared.
- queue isn't working. I have many episodes that are ready to play but queue says empty
- Played card is still as prominent as unplayed. I expected it to be greyed out
- It shouldn't say "preparing clean playback" It could just say preparing 

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
