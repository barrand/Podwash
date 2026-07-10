"""Cursor SDK bridge launch helpers.

cursor-sdk 0.1.9 generates tool/store callback auth tokens via
``secrets.token_urlsafe(32)``. Those tokens may start with ``-`` (~1–2% of
draws). The vendored bridge's argv parser treats any value starting with ``-``
as a missing flag value, so ``launch_bridge`` fails with:

  Missing value for --tool-callback-auth-token

This module patches token generation to reject dash-prefixed tokens and retries
once more if that specific parse error still surfaces.
"""

from __future__ import annotations

import secrets
from typing import Any

_DASH_TOKEN_ERR = "Missing value for --tool-callback-auth-token"
_DASH_STORE_TOKEN_ERR = "Missing value for --store-callback-auth-token"
_PATCHED = False


def bridge_safe_auth_token() -> str:
    """URL-safe token that never starts with ``-`` (bridge argv-safe)."""
    while True:
        token = secrets.token_urlsafe(32)
        if not token.startswith("-"):
            return token


def install_dash_safe_auth_tokens() -> None:
    """Patch cursor-sdk token generators so bridge argv parsing cannot reject them."""
    global _PATCHED
    if _PATCHED:
        return
    import cursor_sdk._store_callback as store_callback
    import cursor_sdk._tool_callback as tool_callback

    tool_callback._new_auth_token = bridge_safe_auth_token
    store_callback._new_auth_token = bridge_safe_auth_token
    _PATCHED = True


def is_dash_prefixed_token_argv_error(err: BaseException) -> bool:
    msg = str(err)
    return _DASH_TOKEN_ERR in msg or _DASH_STORE_TOKEN_ERR in msg


def launch_bridge(workspace: str, *, max_attempts: int = 3, **kwargs: Any) -> Any:
    """``CursorClient.launch_bridge`` with dash-safe tokens + targeted retries."""
    from cursor_sdk import CursorClient
    from cursor_sdk.errors import CursorSDKError

    install_dash_safe_auth_tokens()
    last_err: BaseException | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            return CursorClient.launch_bridge(workspace=workspace, **kwargs)
        except CursorSDKError as err:
            last_err = err
            if is_dash_prefixed_token_argv_error(err) and attempt < max_attempts:
                continue
            raise
    assert last_err is not None
    raise last_err
