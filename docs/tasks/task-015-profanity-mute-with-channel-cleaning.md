# Task 015 — Profanity mute when Clean channel / Clean Profanity is on

| Field | Value |
|-------|-------|
| **ID** | 015 |
| **Title** | Profanity mute when channel cleaning is on (ads skip but F-bomb audible) |
| **Status** | Done |
| **Done at** | 2026-07-14T18:48:58Z |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/PlaybackEngine.swift`, `PodWash/PodWash/IntervalScheduler.swift`, `PodWash/PodWash/WhisperKitASRTranscriber.swift`, `PodWash/PodWash/WordMatcher.swift`, `PodWash/PodWash/IntervalBuilder.swift`, `PodWash/PodWash/AnalysisTimelineModel.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift`, `PodWash/PodWashTests/SegmentationIntegrationTests.swift` |
| **Crux** | With channel cleaning on, a local downloaded episode, and analysis complete, every word that appears in the ASR transcript and matches the Settings target set (including default `fWord` / `"fuck"`) produces a `.profanity` mute interval that is applied to `PlaybackEngine` — ads can skip without leaving target words unmuted. |

## Outcome

**Observed (device, user-confirmed):** This American Life episode downloaded; **Clean channel** on; analysis timeline finished; **Skip ads** worked (ad skipped). An F-bomb in roughly the first minute was still audible.

**Expected:** Same session mutes F-words (default profile includes `fWord`). Ad skip and profanity mute are independent interval sources from one analyze (`IntervalSource.profanity` vs `.unrelatedContent`).

**Framing:** If a test proves channel-on + local file + transcript containing `"fuck"` yields ≥1 applied `.profanity` mute on the engine (and dual-source union keeps both skip + mute), we never need to re-listen for “toggle on but words leak” wiring. Device TAL remains a human checklist for ASR recall / timestamp accuracy.

## Debug notes (intake investigation 2026-07-14)

### What “working ads + finished timeline” actually proves

| Observation | What it proves | What it does **not** prove |
|-------------|----------------|----------------------------|
| Episode downloaded | Local-file gate passed (`AppShellModel` only analyzes `file://`) | — |
| Timeline finished (green/yellow) | ASR (or cache hit) completed; `processedEnd == duration` | That any **profanity** was matched |
| Yellow buckets / ad skipped | `HeuristicContentSegmenter` found unrelated spans; projected `.unrelatedContent` + `.skip` reached `PlaybackEngine` boundary observers | That `.profanity` intervals exist or that `audioMix` mute ramps exist |
| F-bomb audible | Spoken audio at that time was **not** silenced (or silence window missed the word) | Whether Console had `profanity=0` vs mistimed mute |

**Critical UX/code fact:** The analysis timeline paints **yellow only for ads** (`adRanges` from `.unrelatedContent`). Profanity mute intervals **do not appear** on the strip (`AnalysisTimelineModel.completeSnapshot` / ADR-018). A fully green+yellow timeline is compatible with **`profanity=0`**.

**Skip vs mute plumbing (why ads can work alone):**

- `IntervalScheduler.makeAudioMix` builds volume ramps for **`.mute` only**; returns **`nil` when there are zero mute intervals**.
- Skip uses **boundary time observers** + seek (`PlaybackEngine.applySchedule`), independent of `audioMix`.
- So: **ads-only union → skips fire, `item.audioMix == nil`, every word plays at full volume.** That matches this report exactly if ASR produced no matched target tokens.

### Pipeline (intended path)

```
playEpisode (channel cleaning on + local file)
  → PlaybackCoordinator.preparePlayback(
        targetWords: SettingsStore.activeNormalizedTargetSet(),  // includes fWord by default
        action: censorAction() → .mute by default,
        unrelatedContent: channel Skip-ads toggle…)
  → AnalysisPipeline.analyze
        → WhisperKitASRTranscriber (tiny.en, wordTimestamps: true, cpuOnly)
        → IntervalBuilder.buildIntervals (exact normalize + set membership)
        → HeuristicContentSegmenter → unrelated spans
        → cache union; project both sources
  → applySchedule → mute mix + skip observers
  → Console: preparePlayback done … profanity=N unrelatedPlayback=M
```

### Ranked failure hypotheses

Ordered by fit to **this** report (downloaded + timeline done + ad skipped + F-bomb heard).

#### H1 — ASR never emitted a matchable token (most likely)

**Mechanism:** `openai_whisper-tiny.en` omits, mishears, or rewrites the swear (`frick`, `forget`, blank, `[MUSIC]`, etc.). Matcher is **exact set membership** after `WordMatcher.normalize` (matching-spec §4) — **no fuzzy / substring**. No token in `targetSet` → **0** `.profanity` intervals → **nil audioMix** → word plays; ads still skip.

**Why likely:** Fast/dogfood suite never asserts live Whisper on swear audio. Spike/slow fixtures use pangram / non-profanity targets. Tiny model + podcasts is a known weak spot for rare/short swear tokens.

**Falsify with Console:** `preparePlayback done … profanity=0 unrelatedPlayback≥1`.

**Fix class:** ASR quality / decode options / larger model (escalate to **slice**, not bend mute tests); optional future: surface “0 words muted” in UI.

#### H2 — ASR token form does not exact-match the seed list

**Mechanism:** Whisper emits a form not in `WordCategories.fWordSeeds` after normalize — e.g. unexpected punctuation interior, hyphenation, or a novel obfuscation. Seeds include many `f*ck` / `fck` / `phuck` variants, but **not every** ASR spelling. Exact membership fails → same as H1 (`profanity=0`).

**Falsify:** Dump first ~2 min of timed words from cache/transcript for that episode; find the spoken swear’s ASR string; check `WordMatcher.matches(normalize(token), in: activeNormalizedTargetSet())`.

#### H3 — Mute interval exists but timestamps miss the spoken word

**Mechanism:** Matcher hits `"fuck"` / `"fucking"`, mute mix applied, but Whisper word `start`/`end` are off by more than padding (`START_PADDING=0.08`, `END_PADDING=0.12`, `MIN_CENSOR=0.18`). Live ASR tolerance in slow tests is **±200 ms** (ADR-003 / Slice 07); a larger bias leaves the real phoneme **outside** the silent window. User hears the bomb; Console shows **`profanity≥1`**.

**Falsify:** Console `profanity≥1` + seek to logged interval times while watching waveform / listening — silence is elsewhere than the swear.

**Fix class:** Timestamp alignment, more padding (product/spec change), or better ASR timings — not “toggle broken.”

#### H4 — Settings / action configuration (less likely if defaults untouched)

| Setting | Effect if wrong |
|---------|-----------------|
| `fWord` category off in Settings | `"fuck"` not in `activeNormalizedTargetSet()` → H1-like |
| `defaultCleaningAction == .skip` | Would **seek past** the word, not play it; user reported **hearing** it → argues against skip-as-action unless seek failed |
| Channel cleaning off | Would also skip analysis entirely → **no ad skip** either; ruled out by report |

**Falsify:** Settings → F-word still ON; Cleaning action = Mute.

#### H5 — Wiring bug: unrelated skip kept, profanity dropped (unlikely but testable)

**Mechanism:** Bug in `AnalysisPipeline.project`, cache decode, or `PlaybackCoordinator.applySchedule` that drops `.profanity` while keeping `.unrelatedContent`.

**Code read (intake):** `project` remaps both sources; coordinator maps both; `makeAudioMix` filters `.mute` only. No obvious drop path. Dual-source integration tests already exist for injected transcripts (`SegmentationIntegrationTests`). Still worth AC3 as a regression lock.

**Falsify:** Injected transcript with both `"fuck"` and a segmentable ad span → both sources in `cachedIntervals` and mute ramps present (ACs 1–3).

#### H6 — Ruled out / low priority for this report

| Hypothesis | Why weak here |
|------------|---------------|
| Streaming / no local file | User: downloaded; ads need analysis which requires local file |
| Analysis still running when word played | User: timeline finished; library path waits on prepare before queued play |
| “Timeline finished” means mutes applied | Timeline never paints mute intervals (ADR-018) |
| Mute overlay / beep missing | Default overlay is **off** = **silence**; silence is the mute. Hearing the word ≠ “no beep” |

### First diagnostic step (human, before / during factory)

On device, Console filter `PodWash` / `preparePlayback` while replaying the same episode:

```
preparePlayback done episodeID=… intervals=… profanity=N unrelatedPlayback=M unrelatedDetected=…
```

| Console | Branch |
|---------|--------|
| `profanity=0`, `unrelatedPlayback≥1` | **H1/H2** — ASR/match; wiring ACs may go green while device still fails → escalate model/recall |
| `profanity≥1` | **H3** (or rare mix attach bug) — compare interval times to heard word; inspect `audioMix` |
| prepare failed / skip prepare | Unexpected given ads skipped — capture full log |

Optional: delete episode download + clear interval cache for that episode and re-analyze after Settings confirm F-word ON (rules out stale oddities; cache key already fingerprints target words + `interval-format:v2` + segmenter revision).

### What existing tests already cover vs gap

| Covered | Gap |
|---------|-----|
| Channel cleaning on → `analyze` called; injected `{shit,damn}` → intervals + mute ramps (`ProductionAnalysisWiringTests`) | No injected **`"fuck"`** pin on production play path |
| Dual-source mute+skip with `{shit,damn}` (`SegmentationIntegrationTests`) | Same, not live ASR |
| Default Settings include fWord (`SettingsStoreTests` asserts `"fuck"`) | Does not prove Whisper emits `"fuck"` on TAL |
| Live Whisper pangram / non-swear slow tests | **No** live swear-word recall or mute-on-real-speech gate |

## Acceptance criteria

- [x] 1. Unit test (`AppShellModel` / `PlaybackCoordinator` + injected transcript containing a timed `"fuck"`, channel cleaning **on**, local file, default Settings target set): after prepare, `cachedIntervals` contains **≥ 1** interval with `source == .profanity`, `action == .mute`, and the word’s padded bounds match `IntervalBuilder` / matching-spec padding within **±0.0005 s**.
- [x] 2. Unit test (same setup + offline mix): `AudioMixRampInspector` mute onset/release boundaries match that profanity interval’s `start`/`end` each within **±0.001 s** (same pattern as `testPlayEpisodeAppliesMuteScheduleToEngine`).
- [x] 3. Unit test (`AnalysisPipeline` project / play prepare): injected transcript with **≥ 1** target profanity word **and** **≥ 1** segmentable unrelated span; unrelated enabled with `.skip`, profanity `.mute` → returned/applied intervals include **both** `source == .profanity` (mute) **and** `source == .unrelatedContent` (skip) — neither source drops the other. Documents H5 regression lock.
- [x] 4. Unit test (`SettingsStore` defaults): `WordMatcher.matches("fuck", in: store.activeNormalizedTargetSet()) == true` on a fresh store (pin dogfood default; extend existing coverage only if missing).

**Done for this ticket** = AC1–4 green. If human Console still shows `profanity=0` on TAL after that, **do not** weaken mute tests — open ASR/model follow-up (slice) and leave checklist unchecked / Halt with note.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeMutesFuckFromInjectedTranscriptWhenChannelCleaningOn()` | yes |
| 2 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeAppliesProfanityMuteRampsForFuckInterval()` | yes |
| 3 | `PodWashTests/SegmentationIntegrationTests/testProfanityMuteAndUnrelatedSkipBothProjected()` | yes (or extend existing dual-source test) |
| 4 | `PodWashTests/SettingsStoreTests/testCategoryToggleUpdatesTargetSet()` | no — assert `"fuck"` already present; only add if missing |

## Authorized test changes

- (none — bug fix; do not weaken existing mute/skip thresholds)

## Depends on

- None

## Out of scope

- Renaming “Clean channel” → “Clean Profanity” (task-016; separate ticket)
- Upgrading Whisper model size / ANE tuning / non-`cpuOnly` on device (escalate to slice if ACs pass and device still `profanity=0`)
- Changing default word categories or matching-spec algorithm (unless H2 proves a missing seed with a concrete ASR token)
- Painting mute intervals on the analysis timeline (UX follow-up; would have made this failure obvious)
- Streaming cleaned playback

## Human checklist

- [ ] Console on replay: capture `preparePlayback done … profanity=N unrelatedPlayback=M` (see diagnostic table above).
- [ ] Confirm Settings: **F-word** ON, default cleaning action **Mute**.
- [ ] After factory AC green: re-play same TAL download; F-bomb muted **or** documented `profanity=0` → escalate ASR (do not bend mute tests).

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=4 passed=4 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260714-124831.xcresult tier=2 class=tests
```
