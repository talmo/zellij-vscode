VS Code Remote-SSH persistence with Zellij
==========================================

Terminal sessions (including `claude code`) on a remote Linux host survive laptop
sleep, disconnects, and network switches. A Zellij session is auto-created/attached,
named after the current workspace folder.

Design (deliberately un-magic)
------------------------------

- **The VS Code profile is fully self-contained.** All logic lives in the profile
  args — nothing is installed on the server except the `zellij` binary itself, and
  nothing runs on shell login.
- **On a host without zellij, the terminal falls back to a normal login shell**
  instead of crashing the tab. So you can point the same profile at any host.
- **Two explicit one-liners**, each run once, by hand:
  - one on a new **client** to add the VS Code profile
  - one on a new **server** to install zellij

Client setup (run once per client)
-----------------------------------

macOS / Linux:

    curl -fsSL https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-client.sh | bash

Windows (PowerShell):

    irm https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-client.ps1 | iex

Merges a `Zellij` profile into your VS Code User `settings.json` (backing it up
first) and makes it the default Linux profile. Re-running is safe. Requires `jq`
on macOS/Linux; auto-merge on Windows needs PowerShell 7 (otherwise it prints the
block to paste). Reload the VS Code window afterward.

The profile it installs:

```json
"terminal.integrated.profiles.linux": {
  "Zellij": {
    "path": "bash",
    "args": ["-lc", "if command -v zellij >/dev/null 2>&1 && [ -z \"$ZELLIJ\" ]; then zellij attach --create \"$(basename \"$PWD\" | tr ' ' '_')\"; fi; exec \"${SHELL:-bash}\" -l"]
  }
},
"terminal.integrated.defaultProfile.linux": "Zellij"
```

What the command does, in order:

1. `-lc` — login shell, so `$PATH` from your profile is loaded (finds zellij in
   `~/.cargo/bin`, `~/.local/bin`, etc., not just `/usr/local/bin`).
2. `command -v zellij` — **if zellij isn't installed, skip everything** → no crash.
3. `[ -z "$ZELLIJ" ]` — don't nest a session inside an existing one.
4. `zellij attach --create "<folder>"` — attach to / create the per-folder session.
5. `exec "${SHELL:-bash}" -l` — always ends in a real shell, so if you detach, or
   zellij errors (e.g. a version mismatch), the tab stays usable instead of dying.

Server setup (run once per host)
--------------------------------

    curl -fsSL https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-server.sh | bash

Installs the `zellij` binary to `/usr/local/bin` (arch-aware). That is the only
thing that ever touches the server. To pin a version, edit the URL in the script
(`download/vX.Y.Z` instead of `latest/download`).

Raw one-liner, if you'd rather paste it than curl a script:

    t=$(uname -m); case $t in aarch64|arm64) t=aarch64;; *) t=x86_64;; esac; \
    curl -fL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-$t-unknown-linux-musl.tar.gz" \
    | tar xz && sudo install zellij /usr/local/bin/ && rm zellij

Notes
-----

- **Session naming:** the session is `basename $PWD` with spaces → `_`. Two repos
  with the same folder name share a session (they'll mirror). Rename one folder if
  that bites.
- **Mirroring:** opening the same folder on two machines attaches both to one
  session (real-time mirror; viewport shrinks to the smallest client). For
  independent work on one repo, use `git worktree` so the folder names differ.
- **Uninstall / undo:** the client installer leaves a timestamped `.bak` next to
  `settings.json`. Restore it, or delete the `Zellij` profile and reset
  `defaultProfile.linux`.

Manual reference
----------------

| Action | Command |
|--------|---------|
| List sessions | `zellij ls` |
| Force attach | `zellij attach <name>` |
| Kill one | `zellij delete-session <name>` |
| Kill all | `zellij delete-all-sessions` |
| Lock/unlock UI (avoid VS Code key clashes) | `Ctrl+g` |
| New pane / tab | `Alt+n` / `Alt+t` |
| Detach | `Ctrl+o` then `d` |

License
-------

MIT — see [LICENSE](LICENSE).
