#!/usr/bin/env python3
"""Parallel task lane dispatch helpers (Sequel Phase 2).

MVP ships serial task_loop; this module provides disjoint-area scheduling used
by --lanes and unit tests.
"""

from __future__ import annotations

from typing import Any

from task_ticket import areas_overlap


def can_schedule(area: str, in_flight: list[dict[str, Any]]) -> bool:
    """True if ``area`` does not overlap any in-flight task Areas."""
    for item in in_flight:
        if areas_overlap(area, item.get("area") or ""):
            return False
    return True


def pick_parallel_batch(
    candidates: list[dict[str, Any]],
    *,
    max_lanes: int = 2,
) -> list[dict[str, Any]]:
    """Greedy pick up to max_lanes disjoint-area candidates (already priority-sorted)."""
    chosen: list[dict[str, Any]] = []
    for c in candidates:
        if len(chosen) >= max_lanes:
            break
        if can_schedule(c.get("area") or "", chosen):
            chosen.append(c)
    return chosen
