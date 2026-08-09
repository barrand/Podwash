# PodWash App Store listing draft

> **Status:** Draft for the 1.0 release. Treat this file as the source of truth
> for App Store Connect metadata and screenshot production. Do not upload or
> publish the copy until the cloud-transcript consent flow and Gemini service
> plan are confirmed.

## App information

| Field | Draft | Limit / note |
| --- | --- | --- |
| Name | `PodWash` | 30 characters |
| Subtitle | `A cleaner podcast player` | 24 characters; 30-character limit |
| Primary category | Entertainment | Owner to confirm |
| Secondary category | Music | Optional; owner to confirm |
| Price | Free | Confirm before creating the app record |
| Copyright | `© 2026 Barrand Farm` | Replace if the legal developer name differs |
| Support URL | `https://podwash-support.web.app/support` | Publish the Hosting site first |
| Privacy Policy URL | `https://podwash-support.web.app/privacy` | Publish the Hosting site first |
| User Privacy Choices URL | `https://podwash-support.web.app/privacy` | Optional, but recommended once the deletion process is operational |

## Promotional text

> Take control of your podcast listening with custom cleaning controls, a
> focused queue, offline downloads, and optional cloud ad detection.

Promotional text can be changed without submitting a new app version. Recheck
this statement against the final shipped cloud-consent behavior before use.

## Description

PodWash is a podcast player built for more control over how you listen.

Build a library of podcasts, line up what you want to hear next, and keep your
favorites ready for offline listening. PodWash gives you practical playback
tools without making you sign up for an account.

FEATURES

• Shape your listening experience. Choose word categories, add custom words,
  and select whether matching moments are muted or skipped.

• Keep your place. Use playback speed controls, a sleep timer, and a queue that
  keeps the next episode in view.

• Download for later. Save episodes for offline listening and remove them when
  you are done.

• Follow along. Read the on-device transcript as an episode plays and recenter
  it whenever you need to catch up.

• See what is ahead. The playback timeline shows preparation and cleaned
  segments as they become available.

• Choose cloud ad detection. When enabled, this optional feature sends timed
  transcript text—not podcast audio—to identify likely ad breaks. You can turn
  it off in Settings at any time.

Podcast content and recognition results can vary. PodWash’s analysis tools are
designed to give you more control; they do not guarantee that every word or
segment will be detected.

Read the Privacy Policy and get help at podwash-support.web.app.

## Keywords

```text
podcast,audio,player,offline,downloads,transcript,queue,playback,speed,clean listening
```

This draft is 86 bytes, within Apple’s 100-byte limit. Do not add competitor
names, trademarked podcast names, or duplicate words already covered by the
app name and subtitle.

## Screenshot storyboard

Use authentic captures from the final release candidate; do not use generated
or altered screens that misrepresent the app. Use one consistent podcast and
episode sequence across the set. Confirm that displayed podcast artwork, titles,
and episode content are either licensed, public-domain, or otherwise approved
for marketing use.

| # | Screen to capture | Headline overlay | Supporting copy | Required state |
| --- | --- | --- | --- | --- |
| 1 | Discover search results or Library with subscriptions | **Your podcasts, in one place.** | Find a show, build your library, and start listening. | Real or approved sample podcast artwork; no error, empty, or debug state. |
| 2 | Full player with the super seek bar and active playback | **Listen on your terms.** | Control your pace and see what is coming next. | An episode with a visible, truthful prepared timeline. |
| 3 | Settings: Cleaning defaults and Word categories | **Choose what gets cleaned.** | Set your preferred action and tailor the words that matter to you. | No debug sections visible; show actual default controls. |
| 4 | Queue with downloaded/ready episodes | **Ready when you are.** | Keep your next listens organized and available offline. | A credible queue; downloaded state must be genuine. |
| 5 | Transcript view following playback | **Stay with every word.** | Follow the conversation as you listen. | Use an approved transcript and episode; no private or test-only text. |

### Capture rules

- Capture the final Release/TestFlight build, not an Xcode preview or a debug
  build. Remove debug-only UI and diagnostics first.
- Use portrait screenshots with the status bar visible and a consistent time,
  signal, and battery treatment.
- Avoid modal permission prompts, alert dialogs, network failures, placeholder
  content, unfinished progress, and test identifiers.
- Marketing headline overlays are allowed only when the underlying app UI is
  visible and accurately represented. Do not place claims in screenshots that
  the release build cannot support.
- Supply 5 screenshots initially. Apple accepts 1–10 screenshots; five gives a
  clear narrative without filler.

### Required device captures

PodWash supports both iPhone and iPad. Capture the highest required size for
each device family, then let App Store Connect scale to smaller devices when
the UI is equivalent.

| Device family | Recommended simulator | Portrait export size |
| --- | --- | --- |
| iPhone | 6.9-inch iPhone (for example, iPhone 17 Pro Max) | 1320 × 2868 px |
| iPad | 13-inch iPad Pro | 2064 × 2752 px |

Confirm the exact accepted device wells in App Store Connect immediately before
uploading, since Apple updates device requirements. If the iPad presentation is
materially different, capture its own complete 3–5 screen set instead of using
scaled iPhone images.

## App Review notes

Paste and revise the following in App Store Connect after the consent flow is
implemented and tested:

> PodWash does not require a user account. Reviewers can use Discover to search
> for a podcast, open a show, and play an episode. The core podcast, queue,
> download, playback, transcript, and local cleaning features do not require
> cloud ad detection.
>
> Cloud ad detection is optional. Before any timed transcript text is sent to
> Google Gemini, PodWash presents an explicit disclosure and the listener can
> decline. Podcast audio is not uploaded. The listener can withdraw this choice
> in Settings at any time.
>
> For assistance, contact barrandlixo@gmail.com.

Do **not** use these review notes until the stated explicit-disclosure behavior
is present in the submitted build.

## App Privacy responses: preparation notes

Complete App Store Connect’s questionnaire from the final, verified service
configuration—not from this summary alone. The likely disclosures to validate
include:

- User content: timed transcript text sent only when cloud ad detection is
  enabled and consented to.
- Identifiers and diagnostics: anonymous Firebase Authentication identifier,
  App Check material/tokens, IP address, user-agent, request metadata, and any
  Cloud Run or Firebase operational logs.
- Support correspondence: information a user supplies by email.
- Third parties: Firebase Authentication, Firebase App Check, Cloud Run,
  Firestore, Gemini, and Firebase Hosting.
- Retention, deletion, and use of Gemini API data under the selected plan.

## Owner decisions before submission

- [ ] Confirm that `Barrand Farm` is the correct legal developer name for the
  copyright and privacy policy.
- [ ] Choose primary/secondary categories, price, and availability.
- [ ] Complete and test explicit consent before cloud transcript sharing.
- [ ] Confirm Gemini plan, data-use settings, and under-18 eligibility.
- [ ] Implement and test a user-data deletion process that the support address
  can fulfill.
- [ ] Publish and verify the Support and Privacy Policy URLs.
- [ ] Capture release-build screenshots with approved content for iPhone and
  iPad.
- [ ] Confirm every App Privacy response matches the final app and provider
  configuration.

## Sources

- [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple metadata and screenshot upload guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
