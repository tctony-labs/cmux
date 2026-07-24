#!/usr/bin/env bash
# Install cmux's hooks in the Claude Code user settings.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to install the Claude Code hooks." >&2
  exit 1
fi

claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ "$claude_config_dir" == "~" ]]; then
  claude_config_dir="$HOME"
elif [[ "$claude_config_dir" == "~/"* ]]; then
  claude_config_dir="$HOME/${claude_config_dir#"~/"}"
fi
CLAUDE_SETTINGS_PATH="$claude_config_dir/settings.json"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_suffix=".$timestamp.$$.bak"

if ! python3 - "$CLAUDE_SETTINGS_PATH" "$backup_suffix" <<'PY'
import copy
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

settings_path = Path(sys.argv[1]).expanduser()
backup_suffix = sys.argv[2]
existed = settings_path.is_file()

if existed:
    original = json.loads(settings_path.read_text(encoding="utf-8"))
else:
    original = {}

if not isinstance(original, dict):
    raise SystemExit("Claude Code settings must contain a JSON object")

updated = copy.deepcopy(original)
hooks = updated.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("Claude Code settings 'hooks' must contain a JSON object")


def command_hook(command, timeout, *, asynchronous=False):
    hook = {
        "type": "command",
        "command": command,
        "timeout": timeout,
    }
    if asynchronous:
        hook["async"] = True
    return hook


def group(command, timeout, *, matcher="", asynchronous=False):
    return {
        "matcher": matcher,
        "hooks": [command_hook(command, timeout, asynchronous=asynchronous)],
    }


managed_groups = {
    "SessionStart": [group("cmux hooks claude session-start", 10)],
    "Stop": [
        group("cmux hooks claude stop", 10),
        group("cmux hooks feed --source claude", 10, asynchronous=True),
    ],
    "SubagentStop": [
        group("cmux hooks feed --source claude", 10, asynchronous=True),
    ],
    "SessionEnd": [group("cmux hooks claude session-end", 1)],
    "Notification": [group("cmux hooks claude notification", 10)],
    "UserPromptSubmit": [group("cmux hooks claude prompt-submit", 10)],
    "PreToolUse": [
        group("cmux hooks claude cron-create-guard", 5, matcher="CronCreate"),
        group("cmux hooks claude pre-tool-use", 5, asynchronous=True),
    ],
    "PermissionRequest": [group("cmux hooks feed --source claude", 125)],
}


def is_managed_hook(value):
    if not isinstance(value, dict):
        return False
    command = value.get("command")
    if not isinstance(command, str):
        return False
    return "hooks claude " in command or "hooks feed --source claude" in command


def without_managed_hooks(groups):
    if not isinstance(groups, list):
        raise SystemExit("Claude Code hook event settings must contain JSON arrays")

    kept_groups = []
    for existing_group in groups:
        if not isinstance(existing_group, dict):
            kept_groups.append(existing_group)
            continue
        existing_hooks = existing_group.get("hooks")
        if not isinstance(existing_hooks, list):
            kept_groups.append(existing_group)
            continue
        kept_hooks = [hook for hook in existing_hooks if not is_managed_hook(hook)]
        if kept_hooks:
            kept_group = dict(existing_group)
            kept_group["hooks"] = kept_hooks
            kept_groups.append(kept_group)
    return kept_groups


for event, groups in managed_groups.items():
    existing_groups = hooks.get(event, [])
    hooks[event] = without_managed_hooks(existing_groups) + groups

if updated == original:
    raise SystemExit(0)

settings_path.parent.mkdir(parents=True, exist_ok=True)
backup_path = Path(str(settings_path) + backup_suffix)
if existed:
    backup_path.write_bytes(settings_path.read_bytes())
    os.chmod(backup_path, stat.S_IMODE(settings_path.stat().st_mode))

encoded = json.dumps(updated, ensure_ascii=False, indent=2) + "\n"
fd, temporary_path = tempfile.mkstemp(
    dir=settings_path.parent,
    prefix=f".{settings_path.name}.",
    suffix=".tmp",
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(encoded)
    if existed:
        os.chmod(temporary_path, stat.S_IMODE(settings_path.stat().st_mode))
    os.replace(temporary_path, settings_path)
except BaseException:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise
PY
then
  echo "error: could not update Claude Code settings." >&2
  exit 1
fi

echo "Installed cmux Claude Code hooks in: $CLAUDE_SETTINGS_PATH"
