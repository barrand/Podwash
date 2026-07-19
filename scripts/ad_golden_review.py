#!/usr/bin/env python3
"""Launch the local PodWash ad-golden reviewer."""

from __future__ import annotations

import runpy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


if __name__ == "__main__":
    runpy.run_path(
        str(ROOT / "Tools" / "AdGoldenReviewer" / "server.py"),
        run_name="__main__",
    )
