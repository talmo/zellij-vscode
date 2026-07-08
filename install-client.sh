#!/usr/bin/env bash
# install-client.sh
# Adds a hardened "Zellij" terminal profile to this machine's VS Code User
# Settings. Run ONCE per new client (Mac/Linux). Safe to re-run (idempotent).
#
#   curl -fsSL https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-client.sh | bash
#
# The profile is fully self-contained: on a Remote-SSH host WITHOUT zellij it
# falls back to a normal login shell instead of crashing the tab.
#
# The merge is done by merge_settings.py via `uv run` (uv supplies the Python;
# no system Python is used). It is JSONC-aware (preserves your comments and
# trailing commas), backs up settings.json first, and validates the result
# parses before writing. An explicit settings.json path may be passed as $1;
# otherwise it is auto-detected.
set -euo pipefail
RAW="https://raw.githubusercontent.com/talmo/zellij-vscode/main"

if command -v uv >/dev/null 2>&1; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$here" ] && [ -f "$here/merge_settings.py" ]; then
    exec uv run --no-project "$here/merge_settings.py" "$@"   # local clone
  fi
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT             # curl | bash
  merge="$tmpd/merge_settings.py"   # .py name: `uv run` treats it as a script,
                                    # not an executable to spawn
  curl -fsSL "$RAW/merge_settings.py" -o "$merge"
  uv run --no-project "$merge" "$@"
  exit $?
fi

# --- fallback: no uv -> print the block to paste manually ---
cmd='if command -v zellij >/dev/null 2>&1 && [ -z "$ZELLIJ" ]; then zellij attach --create "$(basename "$PWD" | tr '"'"' '"'"' '"'"'_'"'"')"; fi; exec "${SHELL:-bash}" -l'
echo "uv not found; add this to VS Code User settings.json manually:" >&2
echo
echo "\"terminal.integrated.profiles.linux\": {"
echo "  \"Zellij\": { \"path\": \"bash\", \"args\": [\"-lc\", \"$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')\"] }"
echo "},"
echo "\"terminal.integrated.defaultProfile.linux\": \"Zellij\","
exit 1
