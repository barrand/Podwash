# Golden Retriever

Local, dark-mode transcript reviewer for building human-approved ad goldens.
It does not touch the player, factory, audio, or production ad detector.

Start it from the repository root:

```sh
python3 scripts/ad_golden_review.py
```

Then open `http://127.0.0.1:8765`.

The browser writes edits directly and atomically to
`tmp/ad-eval/cougar-sports/review.json`. The human reviewer does not edit or
export JSON. Final approval writes the compact tracked artifact to
`eval/ad-detection/goldens/cougar-sports.json`.

The reviewer refuses approval until the complete transcript has been marked
reviewed, every missed-ad audit item is resolved, the attestation is checked,
and transcript/proposal hashes still match.
