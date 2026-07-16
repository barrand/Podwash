# Follow-up: Offline download shelf vs warm analyze pool

**Status:** Deferred — separate grilling session (not in ADR-029 ship scope).

## Why separate

Smart autoplay warms **2–3** episodes (cap **5** analyzed-but-unplayed) for seamless
handoffs. Road-trip / offline continuity needs a **larger download shelf** that can
exceed the analyze warm pool without cooking the phone on ASR.

## Questions for the next session

1. How many hours / episodes of audio to keep downloaded for offline?
2. Wi‑Fi-only vs cellular for shelf fills vs warm pairs?
3. Auto-delete after play / after N days / storage pressure?
4. Charging / Low Power gates for opportunistic analyze of the shelf into the warm pool?
5. How Coming up readiness indicators surface “downloaded but not analyzed”?

## Interface to ADR-029

- `WarmPlanner` consumes predicted Coming up IDs and pair-downloads+analyzes.
- Download policy should fill a shelf; warm planner prefers already-local files when
  present (future enhancement) while keeping the 5-slot analyze cap.
