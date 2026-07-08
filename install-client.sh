#!/usr/bin/env bash
# install-client.sh
# Adds a hardened "Zellij" terminal profile to this machine's VS Code User
# Settings. Run ONCE per new client (Mac/Linux). Safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-client.sh | bash
#
# The profile is fully self-contained: on a Remote-SSH host WITHOUT zellij it
# silently falls back to a normal login shell instead of crashing the tab.
set -euo pipefail

# --- locate VS Code User settings.json (Code, then Insiders, then VSCodium) ---
case "$(uname -s)" in
  Darwin) base="$HOME/Library/Application Support" ;;
  *)      base="${XDG_CONFIG_HOME:-$HOME/.config}" ;;
esac
settings=""
for dir in "Code" "Code - Insiders" "VSCodium"; do
  if [ -d "$base/$dir/User" ]; then settings="$base/$dir/User/settings.json"; break; fi
done
: "${settings:=$base/Code/User/settings.json}"
mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] || echo '{}' > "$settings"

# --- the self-contained profile command (single-quoted heredoc: nothing expands here) ---
ZJ_CMD=$(cat <<'EOF'
if command -v zellij >/dev/null 2>&1 && [ -z "$ZELLIJ" ]; then zellij attach --create "$(basename "$PWD" | tr ' ' '_')"; fi; exec "${SHELL:-bash}" -l
EOF
)

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (brew install jq / apt install jq). Aborting without changes." >&2
  exit 1
fi

# Note: Remote-SSH uses the *remote* platform's profile keys, so we write the
# .linux keys even though this client may be a Mac.
profile=$(jq -n --arg cmd "$ZJ_CMD" '{path:"bash", args:["-lc", $cmd]}')

backup="$settings.bak.$(date +%Y%m%d%H%M%S)"
cp "$settings" "$backup"

if jq -e . "$settings" >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --argjson profile "$profile" '
    (.["terminal.integrated.profiles.linux"] // {}) as $p
    | .["terminal.integrated.profiles.linux"] = ($p + {Zellij: $profile})
    | .["terminal.integrated.defaultProfile.linux"] = "Zellij"
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "OK  Updated $settings"
  echo "    Backup: $backup"
else
  echo "!!  $settings has comments/trailing commas (JSONC); not auto-editing to"
  echo "    avoid corrupting it. Backup at $backup. Paste this in manually:"
  echo
  echo "\"terminal.integrated.profiles.linux\": { \"Zellij\": $profile },"
  echo "\"terminal.integrated.defaultProfile.linux\": \"Zellij\","
fi
