# Played episode card and automatic download cleanup

## Approved experience

When playback ends for an episode that reached the existing 95% played
threshold, PodWash automatically removes its local audio download. It remains
in the feed as listening history, with its transcript and prior analysis
retained.

- A played row is visually quieter: regular-weight muted title plus
  `date · ✓ Played` metadata.
- All readiness states and primary controls match an otherwise identical
  never-played episode. In the normal post-play state, that means **Not
  downloaded** with the existing download button—not a Play button.
- Downloading, preparing, ready, retry, and failure presentation use the
  existing shared row copy and controls. Do not add “Ready to replay” or other
  replay-only status copy.
- Pressing the normal primary Play control on a played, ready episode starts it
  from the beginning and clears the played styling for the new listening pass.
- The More menu keeps applicable common actions such as Add to Up Next, View
  Transcript, cancellation, and retry. It omits **Mark as Played** because the
  episode is already played.

## Implementation changes

- Make audio cleanup unconditional after natural playback completion and after
  the existing Undo period for manual marking. Remove local audio,
  partial/resume transfer data, and active preparation work; retain the episode
  record, played state, transcript, and durable analysis. Never remove the file
  while it is still the active player source.
- Reconcile existing played episodes at launch and after a library refresh so
  their stale local audio is removed once it is safe to do so.
- Remove the `Remove downloads after playing` setting and its UI, analytics,
  and tests. Retain any old stored preference value but ignore it so there is no
  migration risk for existing installs.
- Remove the played-episode download/replay special-case UI. A played episode
  without audio enters the same download/preparation lifecycle as a new
  undownloaded episode. Keep the internally required fresh-analysis safeguards
  for newly downloaded audio, but do not surface replay-specific row copy or a
  replay-only confirmation.
- Update the shared row presentation and menu policy so played status affects
  only visual hierarchy and the omitted Mark as Played action. The download and
  play controls keep their existing placement, iconography, hit targets, copy,
  and accessibility behavior. Remove the replay-specific overflow action and
  ready banner; the common primary control handles the flow.
- This plan supersedes the auto-delete setting and played-row cleanup guidance
  in `docs/plans/played-episode-replay.md`.

## Verification

- A naturally completed episode deletes local audio only after playback ends,
  and a manually marked-played episode does so after the existing Undo period;
  both retain history, transcript, and analysis.
- Existing played episodes with stale local audio are cleaned up after launch
  or a library refresh, except while actively playing or preparing replay.
- A normal played row has no local file, shows the same Not downloaded/download
  state as a new row, and does not offer Mark as Played.
- Played download, preparation, retry, failure, and ready states match the
  corresponding unplayed row controls and copy, apart from the muted
  title/Played metadata.
- Starting a played episode from its ready Play control begins at zero and
  removes played styling; no stale analysis is reused after a fresh download.
