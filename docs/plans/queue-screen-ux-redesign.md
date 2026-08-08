# Queue Screen UX Redesign

Queue is an ordered listening commitment. Downloads are a collapsed, derived
backlog of locally available episodes; they are not a second queue.

## Experience

- Keep **Up Next** as the only ordered list. In normal mode, rows play on tap,
  swipe left to **Remove**, and expose Play now, Move to top, Mark as played,
  Remove from Up Next, and Remove download in the More menu.
- Use an explicit **Reorder** button. It activates native edit mode and its
  right-side handles; **Done**, leaving the tab, or fewer than two entries ends
  reorder mode. Swipe and row playback are disabled while reordering.
- Replace **Ready to Play** with a collapsed, persisted **Downloads** disclosure.
  It contains verified local files, excluding Now Playing, Up Next, and played
  episodes. It sorts by preparation update, then publication date.
- Do not repeat the word Ready. Show only exceptional activity in caption-sized
  metadata: Downloading percent, Preparing clean playback, Checking for ads,
  Ad check delayed, or Needs attention.
- Keep action controls fixed: More gets a 44-point target; the native reorder
  control sits outside it. Titles may use two lines; metadata uses one.
- Mark as Played removes an item from active presentation, preserves audio when
  auto-delete is off, and offers Undo for five seconds. Explicit replay resets
  played state and position before adding an episode back to Up Next.

## Architecture

`QueueStore`, `ResumePositionStore`, `DownloadManager`, `WarmPlanner`, and
`PodcastStore` remain the source of truth. There is no Saved-for-Later entity
or Core Data migration.

`QueuePresentationBuilder` is a pure mapper from queue IDs, verified downloaded
IDs, Now Playing, played state, metadata, and preparation jobs to two display
collections: `upNext` and `downloads`. Views do not read Core Data or inspect
`AnalysisJob` directly.

`AppShellModel` gathers the input, owns mutations and `QueueUndoSnapshot`, and
bumps `queuePresentationRevision` whenever queue, playback, played, download,
or preparation-job state changes. `DownloadManager` has multicast state-change
handlers and `WarmPlanner` notifies job changes so this refresh is reliable.

## Verification

- Unit-test presentation filtering, deterministic Downloads ordering, quiet ready
  status, replay reset, queue-order restore, and played/download behavior.
- UI-test normal swipe removal, Undo, Reorder/Done persistence, More-menu
  alignment with long titles, collapsed Downloads, dynamic type, VoiceOver, and
  mini-player clearance.
- Verify Now Playing and played episodes never appear in Downloads.
