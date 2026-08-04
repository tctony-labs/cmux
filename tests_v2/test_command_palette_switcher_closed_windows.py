#!/usr/bin/env python3
"""Regression test: cmd+p switcher excludes open-workspace commands from closed windows."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 6.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"palette visibility in {window_id} did not become {visible}",
    )


def _open_switcher(client: cmux, window_id: str) -> None:
    _set_palette_visible(client, window_id, False)
    client.focus_window(window_id)
    client.simulate_shortcut("cmd+p")
    _wait_until(
        lambda: _palette_visible(client, window_id),
        message=f"switcher in {window_id} did not become visible",
    )
    _wait_until(
        lambda: str(client.command_palette_results(window_id).get("mode") or "") == "switcher",
        message=f"command palette in {window_id} did not enter switcher mode",
    )


def _switcher_command_ids(client: cmux, window_id: str) -> set[str]:
    payload = client.command_palette_results(window_id=window_id, limit=256)
    return {
        str((row or {}).get("command_id") or "")
        for row in payload.get("results") or []
    }


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        window_a = client.current_window()
        window_b = client.new_window()
        workspace_b = client.new_workspace(window_id=window_b)
        token = f"cmdp-closed-window-{int(time.time() * 1000)}"
        client.rename_workspace(token, workspace=workspace_b)
        target_command = f"switcher.workspace.{workspace_b.lower()}"

        _open_switcher(client, window_a)
        _wait_until(
            lambda: target_command in _switcher_command_ids(client, window_a),
            message="switcher did not include the workspace while window B was open",
        )
        _set_palette_visible(client, window_a, False)

        client.close_window(window_b)
        _open_switcher(client, window_a)
        _wait_until(
            lambda: target_command not in _switcher_command_ids(client, window_a),
            message="switcher still included the open-workspace command after window B closed",
        )

    print("PASS: cmd+p switcher excludes open-workspace commands from closed windows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
