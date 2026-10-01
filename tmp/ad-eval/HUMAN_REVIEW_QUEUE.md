# Human Review Queue for Ad Goldens

Purpose: convert agent-proposed spans into real human goldens. Do not manually transcribe whole episodes. Use the existing Whisper transcript, `MARKUP.md`, `REVIEW.html`, and the local `audio.mp3` files.

## How to Review a Span

For each span below:

1. Open the episode `MARKUP.md` and the episode `audio.mp3`.
2. Play from about 10 seconds before the proposed start to 10 seconds after the proposed end.
3. In `MARKUP.md`, mark exactly one review checkbox:
   - `[x] agree` only if the start/end are good enough as word-level boundaries.
   - `[x] edit` if it is an ad/promo but the boundary or subtype needs correction; write the corrected time in `Boundary note`.
   - `[x] disagree` if this should remain content.
4. Mark one `Human subtype`.
5. Be conservative at re-entry. If unsure, leave story words out of the ad span.

## Start Here

### 1. Cougar Sports

File: `tmp/ad-eval/cougar-sports/MARKUP.md`

Audio: `tmp/ad-eval/cougar-sports/audio.mp3`

Why first: exercises the most important failures: DAI cold open, stacked ads, local live-read, and re-entry after dense sponsor blocks.

- Span 1, 0:00-0:28: On Deck cold-open DAI.
- Span 2, 0:29-0:58: SpinQuest cold-open DAI.
- Span 3, 0:58-1:28: Sleep Number cold-open DAI.
- Span 4, 2:29-2:35: Atrium Hotel short segment sponsor.
- Span 5, 23:45-24:02: Atrium Hotel segment sponsor.
- Span 6, 25:12-25:37: Self Serve Mattress local live-read.
- Span 7, 51:09-51:43: On Deck closing ad.
- Span 8, 51:45-52:12: SpinQuest closing ad.
- Hard negative: "It's free. It's ESPN the fan" should remain content unless audio clearly proves otherwise.

### 2. This American Life

File: `tmp/ad-eval/this-american-life/MARKUP.md`

Audio: `tmp/ad-eval/this-american-life/audio.mp3`

Why second: this is the clean re-entry torture test. The old `golden.json` came from a published-transcript diff and has 18 noisy spans; prefer the 11 spans in `MARKUP.md` for human review.

- Span 1, 0:00-0:15: Amazon Health cold-open underwriting.
- Span 2, 7:15-7:28: Carvana.
- Span 3, 7:30-7:43: Capella.
- Span 4, 7:44-8:39: Capital One plus Planet Money Summer School promo.
- Span 5, 30:40-31:05: Schwab.
- Span 6, 31:06-31:30: Mint Mobile.
- Span 7, 31:30-31:45: Carvana.
- Span 8, 31:46-32:18: Capella.
- Span 9, 1:11:37-1:11:42: PRX credit; decide whether this is superfluous non-ad or content.
- Span 10, 1:11:42-1:12:17: Life Partners membership CTA.
- Span 11, 1:13:29-1:13:52: NPR Plus network promo.
- Critical check: do not include story re-entry such as "It's American Life. Act One." in any ad span.

### 3. Darknet Diaries

File: `tmp/ad-eval/darknet-diaries/MARKUP.md`

Audio: `tmp/ad-eval/darknet-diaries/audio.mp3`

Why third: gives cleaner baked-in sponsor reads and useful negative examples.

- Span 1, 1:50-2:42: Threadlocker sponsor read.
- Span 2, 2:47-3:42: Mays sponsor read.
- Span 3, 35:06-36:12: NetSuite sponsor read.
- Span 4, 1:09:05-1:09:26: Darknet Diaries Plus membership CTA.
- Hard negatives: show intro, guest book plug, and break teaser should stay content.

### 4. AI Daily Brief

File: `tmp/ad-eval/ai-daily-brief/MARKUP.md`

Audio: `tmp/ad-eval/ai-daily-brief/audio.mp3`

Why fourth: useful stacked midroll, but less valuable than Cougar/TAL for the immediate detector design.

- Span 1, 0:26-0:40: sponsor thanks plus Patreon/ad-free pitch.
- Span 2, 10:45-11:25: KPMG sponsor read.
- Span 3, 11:26-12:12: Blitzy sponsor read.
- Span 4, 12:12-12:56: Retool sponsor read.
- Span 5, 12:56-13:35: Hyperagent sponsor read.
- Hard negative: show open/headlines should stay content.

## After You Review

When all desired spans in an episode are marked in `MARKUP.md`, regenerate its golden with:

```bash
python3 scripts/ad_eval_golden.py --show cougar-sports --from-markup --reviewer "Brian"
```

Repeat with `--show this-american-life`, `--show darknet-diaries`, or `--show ai-daily-brief` as each episode is finished.

Only use metrics from episodes whose `golden.json` status returns to `human-approved` with a real human reviewer.
