# progressive-120s.m4a

Synthetic 120.0 s mono AAC sine (300 Hz) for `-UITestFixtureProgressivePlayback`.

Generated with ffmpeg lavfi `sine=frequency=300:duration=120` so seek/elapsed/remaining
UITests can assert against the slice-25 duration pin (120.0 s) without relying on
the 30 s `test-clip.m4a`.
