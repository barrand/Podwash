# Midroll closer + host resume — provenance (slice-34 / heuristic-cue-v6)

**Labeler:** QA hand-scripted (not from segmenter output)  
**Date:** 2026-07-16

Synthetic midroll: opener → brand copy → URL + FDIC-style closer → host resume
("Okay, so from the start…"). **No** show titles / act markers.

| Span | Start (s) | End (s) | Class |
|------|-----------|---------|-------|
| Ad | 10.0 | 18.5 | Positive — `This message comes from` through `FDIC.` |
| Host | 19.0 | 25.0 | Negative — must not be inside any predicted segment |

Golden end snaps to last ad token (`FDIC.` ends 18.5). Host resume begins at
`Okay,` (19.0 s). AC allows end within ±2.0 s of golden.
