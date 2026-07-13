# Task 003 — CarPlay disconnect uses wrong protocol selector

| Field | Value |
|-------|-------|
| **ID** | 003 |
| **Title** | CarPlay disconnect uses wrong protocol selector |
| **Status** | In Progress |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/CarPlaySceneDelegate.swift`, `PodWash/PodWashTests/CarPlayTemplateTests.swift`, `docs/adr/016-carplay-templates.md` |
| **Crux** | `CarPlaySceneDelegate` implements the audio-app disconnect entry point CarPlay actually calls, so teardown runs when the CarPlay scene disconnects. |

## Outcome

**Observed:** Xcode warns that `templateApplicationScene(_:didDisconnect:)` on `CarPlaySceneDelegate` “nearly matches” optional requirement `templateApplicationScene(_:didSelect:)` — i.e. it is **not** a protocol witness. For non-navigation (audio) apps, Apple documents `templateApplicationScene(_:didDisconnectInterfaceController:)`. Current method + ADR-016 §7 sketch use `didDisconnect interfaceController:`, so CarPlay likely never invokes cleanup (`coordinator?.clearInterfaceController()`, nil-out refs).

**Expected:** Delegate implements `templateApplicationScene(_:didDisconnectInterfaceController:)`. Build no longer emits the “nearly matches … didSelect” warning for this method. ObjC runtime reports the delegate responds to `templateApplicationScene:didDisconnectInterfaceController:`.

## Acceptance criteria

- [ ] 1. Unit test: `CarPlaySceneDelegate.instancesRespond(to:)` is **true** for `NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")`.
- [ ] 2. App source declares `templateApplicationScene(_:didDisconnectInterfaceController:)` (not `didDisconnect interfaceController:` alone); building PodWash emits **0** warnings matching `nearly matches optional requirement.*didSelect` for `CarPlaySceneDelegate`.
- [ ] 3. ADR-016 §7 disconnect sketch matches the audio-app selector name (doc only; keeps factory from reintroducing the typo).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/CarPlayTemplateTests/testSceneDelegateRespondsToAudioAppDisconnectSelector()` | yes |
| 2 | — (compile / warning absence; verified with AC1 green + source review in worker) | — |
| 3 | — (ADR text) | — |

## Authorized test changes

- (none — bug fix; new test only)

## Depends on

- None

## Out of scope

- Broader Xcode warning hygiene (`nonisolated(unsafe)`, MainActor fixture/`placeholder` isolation, `MonotonicClock` Swift 6 capture) — separate intake if desired
- CarPlay connect path, templates, now-playing, or plist scene count
- Navigation-app disconnect (`didDisconnect:from:`) — PodWash is audio, not navigation
- Physical CarPlay head-unit session (selector assert is the Done gate)

## Human checklist

- (none — AC1 is the falsifiable proxy)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-102404.xcresult tier=2 class=tests
```
