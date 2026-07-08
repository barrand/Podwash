# PodWash PWA Playback Spike

Static PWA for testing offline podcast playback viability on mobile.

## Local Smoke Test

```bash
cd pwa-spike
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173`.

## Deploy

Create or enable Firebase Hosting for project `gen-lang-client-0583348292`
with site ID `gen-lang-client-0583348292`, then run:

```bash
cd pwa-spike
firebase deploy --only hosting --project gen-lang-client-0583348292
```

Install the HTTPS URL on iPhone and Android before running the manual test cards.
