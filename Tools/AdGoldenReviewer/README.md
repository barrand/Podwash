# Golden Retriever

Local, dark-mode transcript reviewer for building human-approved ad goldens.
It does not touch the player, factory, audio, or production ad detector.

Start it from the repository root:

```sh
python3 scripts/ad_golden_review.py
```

Then open `http://127.0.0.1:8765`.

## Typed-policy first-pass audit

Use **Review typed-policy first passes** from the home screen to read the
prepared policy audit. It layers proposed categories over the existing
human-approved ads-only golden: color means the proposed customer-setting
category, and the amber underline means the current golden. This surface is
read-only and never changes a golden, review, or git state.
The overlay currently prefers V7.1, then V7, and finally frozen V6 output.
V7.2 is preserved as a rejected experiment and is not shown by default.

The browser writes edits directly and atomically to
`tmp/ad-eval/cougar-sports/review.json`. The human reviewer does not edit or
export JSON. Final approval writes the compact tracked artifact to
`eval/ad-detection/goldens/cougar-sports.json`.

The reviewer refuses approval until the reviewer supplies the end-to-end
attestation and transcript/proposal hashes still match. The review queue offers
direct jump targets for every proposed span and any optional model notes.
