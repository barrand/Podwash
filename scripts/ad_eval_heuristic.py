#!/usr/bin/env python3
"""HeuristicContentSegmenter port — shared by score + probe."""

from __future__ import annotations

from segmentation_probe import Segment, segment, timed_words_to_tokens  # type: ignore

__all__ = ["Segment", "segment", "timed_words_to_tokens"]
