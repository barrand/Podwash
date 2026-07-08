# PWA Playback Spike Plan

## Summary

Build the smallest possible PWA to test whether PodWash can be a viable cross-platform podcast player shell before investing in native iOS/Android.

This spike tests only:

1. Offline downloaded audio survives close/reopen.
2. Offline playback works in airplane mode.
3. Playback continues with the phone locked.
4. Lock-screen / Bluetooth controls are acceptable.

No transcription, editing, RSS, subscriptions, backend processing, accounts, or podcast UI.

## Key Changes

- Create a separate static PWA folder, e.g. `pwa-spike/`.
- Use one same-origin long MP3 only:
  - `pwa-spike/audio/episode.mp3`
- Use an existing generated MP3 or any podcast-length MP3 copied into the deploy folder.
- Add minimal files:
  - `index.html`
  - `styles.css`
  - `app.js`
  - `manifest.webmanifest`
  - `service-worker.js`
  - `firebase.json`
  - `icons/`
- Deploy with Firebase Hosting for HTTPS phone testing.

## Minimal Experience

One screen:

- Online/offline indicator.
- Storage estimate.
- Native `<audio controls>` player.
- `Download`.
- `Remove`.
- Downloaded/not downloaded state.
- Manual test checklist:
  - close/reopen survived
  - airplane mode playback worked
  - locked playback continued
  - lock-screen/Bluetooth controls acceptable

## Technical Requirements

- Cache app shell during service worker install.
- Cache the MP3 only after the user taps `Download`.
- The `Download` button must fetch and cache the full MP3 response, not rely on audio playback to fill the cache.
- Store downloaded episode state in `localStorage`.
- Store audio in Cache API.
- Use same-origin audio to avoid CORS and opaque-cache problems.
- Add `crossorigin="anonymous"` to the `<audio>` element.
- Support cached audio `Range` requests in the service worker:
  - detect `Range` header
  - read cached MP3 as an `ArrayBuffer`
  - return `206 Partial Content`
  - include `Content-Range`, `Accept-Ranges`, `Content-Length`, and `Content-Type: audio/mpeg`
- Use `navigator.storage.estimate()` to show approximate storage use.
- Try `navigator.storage.persist()` and show whether persistent storage was granted.
- Use Media Session API only with feature detection.
- Include iOS web app tags:
  - `apple-mobile-web-app-capable`
  - `apple-mobile-web-app-title`
  - `apple-mobile-web-app-status-bar-style`
  - `apple-touch-icon`

## Firebase Hosting Notes

- Serve the PWA over HTTPS.
- Add MP3 headers:
  - `Content-Type: audio/mpeg`
  - `Accept-Ranges: bytes`
  - `Cache-Control: public, max-age=31536000`
- Desktop `localhost` is only for smoke testing.
- The real verdict requires an installed Home Screen PWA on actual iPhone and Android devices.

## Test Cards

### Card 1: Close/Reopen Survival

- Download the MP3.
- Close the installed PWA.
- Reopen it.
- Confirm downloaded state remains.
- Confirm audio still plays.

### Card 2: Airplane Mode Playback

- Download the MP3.
- Turn on airplane mode.
- Reopen the installed PWA.
- Confirm audio plays offline.
- Confirm seeking works.

### Card 3: Phone-Lock Playback

- Start downloaded audio.
- Lock the phone.
- Confirm playback continues for at least 3 minutes.

### Card 4: Lock-Screen / Bluetooth Controls

- While locked, test pause/play.
- If available, test seek/Bluetooth controls.
- Record whether controls are good, limited, or broken.

## Acceptance Criteria

- PWA installs from Firebase HTTPS URL on iPhone and Android.
- Long MP3 downloads successfully.
- Download survives close/reopen.
- Airplane mode playback works.
- Offline seeking works.
- Locked-phone playback is acceptable.
- Lock-screen/Bluetooth controls are acceptable or clearly documented as a blocker.
- If any test fails, the failure mode is specific enough to decide whether PWA remains viable.

## Sources

- Chrome: Serving cached audio and video: https://developer.chrome.com/docs/workbox/serving-cached-audio-and-video
- Workbox Range Requests: https://developer.chrome.com/docs/workbox/modules/workbox-range-requests
- MDN Service Worker API: https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API
- MDN Range requests: https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Range_requests
- MDN Storage quotas and eviction: https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria
- Apple Safari web app meta tags: https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariHTMLRef/Articles/MetaTags.html
