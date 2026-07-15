# Forge MVP gate

**Cleared (Forge Unification)** — unified loop is the default via `scripts/forge.sh` / Floor **Start Forge**.

## Checklist (historical)

- [x] Punch lists filed via `forge-intake` without skipping the grill
- [x] Forge Floor is the habitual **Start** path
- [x] Soft controls (pause / Ship now / requeue) used successfully at least once
- [x] Idle-drain or Ship now produced a green full suite + push
- [x] At least one Halted card cleared floor-first (not by editing factory scripts)
- [x] local-dev was deferred while factory-hot (no dirty-tree fights)

## Current defaults

1. `scripts/forge.sh` → `PODWASH_FORGE_LOOP=forge_loop` (tasks + slices, serial)
2. Floor **Start Forge** starts the unified runner
3. Item exit = tier-2 → **Implemented**; ship gate = **Full verify & ship** (tier-3a then tier-3)
4. `task-loop.sh` is a thin alias to `forge.sh`; `slice-loop.sh` remains the Medic wrapper (set `PODWASH_FORGE_LOOP` to choose the loop module)
