# test-clip.m4a

Generated locally with:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=30" -c:a aac -b:a 64k test-clip.m4a
```

30 s, 440 Hz sine wave, AAC 64 kbps (~247 KB). Independent of `PlaybackEngine` implementation.

A copy lives in `PodWash/Fixtures/audio/` for the app UI-test fixture mode (`-UITestFixtureAudio`).
