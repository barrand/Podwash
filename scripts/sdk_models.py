#!/usr/bin/env python3
"""Cursor SDK model selection — avoid default fast variants.

Passing a bare model id (e.g. ``composer-2.5``) to the Agents SDK resolves to
the **fast** variant and bills as ``composer-2.5-fast`` / ``grok-4.5-fast``.
PodWash wants standard Composer 2.5 and Grok 4.5 High (``fast=false``).

Uses ``Mapping``-shaped dicts accepted by ``AgentOptions.model`` so unit tests
do not require ``cursor_sdk`` installed.
"""

from __future__ import annotations

from typing import Any

# Base ids — match ROLE_MODELS in slice_pipeline.py
COMPOSER_MODEL = "composer-2.5"
GROK_MODEL = "grok-4.5"

# Never use these in the factory SDK path.
FORBIDDEN_MODEL_IDS = frozenset(
    {
        "composer-2.5-fast",
        "grok-4.5-fast",
        "grok-4.5-fast-xhigh",
    }
)


def _model_selection(model_id: str, *, effort_high: bool = False) -> dict[str, Any]:
    params: list[dict[str, str]] = [{"id": "fast", "value": "false"}]
    if effort_high:
        params.append({"id": "effort", "value": "high"})
    return {"id": model_id, "params": params}


def sdk_model_from_id(model_id: str) -> Any:
    """Return SDK model dict with ``fast=false`` for Composer/Grok."""
    mid = (model_id or "").strip()
    if not mid or mid == "auto":
        return mid or "auto"
    if mid in FORBIDDEN_MODEL_IDS:
        raise ValueError(
            f"Forbidden fast model id {mid!r} — use {COMPOSER_MODEL} or {GROK_MODEL} "
            "with fast=false via sdk_model_from_id()"
        )
    if mid.startswith("composer-"):
        return _model_selection(mid, effort_high=False)
    if mid.startswith("grok-"):
        return _model_selection(mid, effort_high=True)
    return mid


def sdk_model_for_role(model_id: str) -> Any:
    """Role → SDK model (alias for ``sdk_model_from_id``)."""
    return sdk_model_from_id(model_id)


def format_sdk_model(model: Any) -> str:
    """Compact label for logs (id + key params)."""
    if isinstance(model, str):
        return model
    mid = getattr(model, "id", None)
    if mid is None and isinstance(model, dict):
        mid = model.get("id")
    params = getattr(model, "params", None)
    if params is None and isinstance(model, dict):
        params = model.get("params")
    bits = [str(mid or "?")]
    for p in params or []:
        pid = getattr(p, "id", None) or (p.get("id") if isinstance(p, dict) else None)
        val = getattr(p, "value", None) or (p.get("value") if isinstance(p, dict) else None)
        if pid and val is not None:
            bits.append(f"{pid}={val}")
    return ":".join(bits)
