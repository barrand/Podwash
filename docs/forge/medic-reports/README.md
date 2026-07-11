# Medic reports

Post-mortems written by the Forge Medic supervisor when a slice-loop halt is
diagnosed (`scripts/slice-loop.sh` — Medic on by default).

Each file is one heal attempt (or a refused heal: lane=test, critic block,
denylist, canary failure). Keep these — they are the institutional memory that
used to live only in chat when you ran forge-fix by hand.

Runtime ledger (not committed): `build/test-results/medic-ledger.jsonl`.
