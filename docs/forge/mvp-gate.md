# Forge MVP gate

**Do not start Sequel 1.5b (unified loop) or Phase 2 (lanes) until this gate passes.**

## Checklist (~2 weeks real use)

- [ ] Punch lists filed via `forge-intake` without skipping the grill
- [ ] Forge Floor is the habitual **Start** path
- [ ] Soft controls (pause / Ship now / requeue) used successfully at least once
- [ ] Idle-drain or Ship now produced a green full suite + push
- [ ] At least one Halted card cleared floor-first (not by editing factory scripts)
- [ ] local-dev was deferred while factory-hot (no dirty-tree fights)

## Then

1. Sequel 1.5b: `PODWASH_FORGE_UNIFIED=1 scripts/forge.sh`
2. Phase 2 lanes only if **throughput** (not visibility) is still the bottleneck

If MVP does not change how you work, **stop** — do not boil the ocean.
