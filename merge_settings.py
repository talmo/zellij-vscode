#!/usr/bin/env -S uv run --no-project --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Merge the Zellij terminal profile into a VS Code settings.json.

Run via `uv run --no-project merge_settings.py` (uv provides the interpreter;
no system Python is required). Standard-library only.

Robust to JSONC (line/block comments, trailing commas): edits are surgical and
comment-preserving, and the result is validated to parse before anything is
written, so the file can never be corrupted. Idempotent and safe to re-run.

Usage: merge_settings.py [path/to/settings.json]
       (with no argument, the VS Code User settings file is auto-detected)
"""
import json
import os
import re
import shutil
import sys
from datetime import datetime

# The self-contained profile command. Remote-SSH runs this on the *remote*
# Linux host, so it targets the .linux profile keys. If zellij is absent it
# falls back to a normal login shell instead of crashing the tab.
CMD = ('if command -v zellij >/dev/null 2>&1 && [ -z "$ZELLIJ" ]; then '
       'zellij attach --create "$(basename "$PWD" | tr \' \' \'_\')"; fi; '
       'exec "${SHELL:-bash}" -l')
PROFILE = {"path": "bash", "args": ["-lc", CMD]}
PROFILES_KEY = "terminal.integrated.profiles.linux"
DEFAULT_KEY = "terminal.integrated.defaultProfile.linux"


# --- string/comment-aware scanning primitives -----------------------------

def skip_string(s, i, n):
    """s[i] == '\"'; return index just past the closing quote."""
    i += 1
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return i  # unterminated


def skip_ws_comments(s, i, n):
    while i < n:
        c = s[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '/':
            i += 2
            while i < n and s[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i < n and not (s[i] == '*' and i + 1 < n and s[i + 1] == '/'):
                i += 1
            i += 2
        else:
            break
    return i


def skip_container(s, i, n):
    """s[i] in '{[' ; return index just past the matching close."""
    stack = [s[i]]
    i += 1
    while i < n and stack:
        c = s[i]
        if c == '"':
            i = skip_string(s, i, n)
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            i += 2
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i < n and not (s[i] == '*' and i + 1 < n and s[i + 1] == '/'):
                i += 1
            i += 2
            continue
        if c in '{[':
            stack.append(c)
        elif c in '}]':
            stack.pop()
        i += 1
    return i


def skip_value(s, i, n):
    i = skip_ws_comments(s, i, n)
    if i >= n:
        return i
    c = s[i]
    if c == '"':
        return skip_string(s, i, n)
    if c in '{[':
        return skip_container(s, i, n)
    j = i
    while j < n and s[j] not in ',}]' and s[j] not in ' \t\r\n' \
            and not (s[j] == '/' and j + 1 < n and s[j + 1] in '/*'):
        j += 1
    return j


def object_members(s, i, n):
    """s[i] == '{'; return (members, close_index).

    members: list of (key, key_start, value_start, value_end).
    """
    i += 1
    members = []
    close_idx = n
    while True:
        i = skip_ws_comments(s, i, n)
        if i >= n:
            break
        if s[i] == '}':
            close_idx = i
            break
        if s[i] == ',':
            i += 1
            continue
        if s[i] != '"':  # malformed; stop scanning
            close_idx = i
            break
        key_start = i
        key_end = skip_string(s, i, n)
        key = json.loads(s[key_start:key_end])
        i = skip_ws_comments(s, key_end, n)
        if i < n and s[i] == ':':
            i += 1
        vs = skip_ws_comments(s, i, n)
        ve = skip_value(s, vs, n)
        members.append((key, key_start, vs, ve))
        i = ve
    return members, close_idx


def indent_of(s, key_start):
    line_start = s.rfind('\n', 0, key_start) + 1
    prefix = s[line_start:key_start]
    return prefix if prefix.strip() == '' else '    '


def to_strict(s):
    """Comment/trailing-comma stripped copy for parsing only (never written)."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = skip_string(s, i, n)
            out.append(s[i:j])
            i = j
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            i += 2
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i < n and not (s[i] == '*' and i + 1 < n and s[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    text = ''.join(out)
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return text


# --- the merge --------------------------------------------------------------

def merge(text):
    """Return (new_text, changed, note). Raises ValueError if unmergeable."""
    n = len(text)
    root_open = skip_ws_comments(text, 0, n)
    if root_open >= n:  # empty / whitespace / comment-only -> empty object
        text, n, root_open = '{}', 2, 0
    if text[root_open] != '{':
        raise ValueError("top-level value is not a JSON object")
    members, _ = object_members(text, root_open, n)
    by_key = {m[0]: m for m in members}

    prof_json = json.dumps(PROFILE, ensure_ascii=False)
    edits = []          # (start, end, replacement)
    append = {}         # key -> value-text, for keys missing at top level

    # profiles.linux
    if PROFILES_KEY in by_key:
        _, ks, vs, ve = by_key[PROFILES_KEY]
        if text[vs] == '{':
            inner, _ = object_members(text, vs, n)
            zellij = next((m for m in inner if m[0] == "Zellij"), None)
            if zellij:
                edits.append((zellij[2], zellij[3], prof_json))
            elif inner:
                last = inner[-1]
                ind = indent_of(text, last[1])
                edits.append((last[3], last[3], ',\n' + ind + '"Zellij": ' + prof_json))
            else:
                ind = indent_of(text, ks) + '    '
                edits.append((vs + 1, vs + 1,
                              '\n' + ind + '"Zellij": ' + prof_json + '\n' + indent_of(text, ks)))
        else:  # value present but not an object; replace it
            edits.append((vs, ve, json.dumps({"Zellij": PROFILE}, ensure_ascii=False)))
    else:
        append[PROFILES_KEY] = json.dumps({"Zellij": PROFILE}, ensure_ascii=False)

    # defaultProfile.linux
    if DEFAULT_KEY in by_key:
        _, _, vs, ve = by_key[DEFAULT_KEY]
        edits.append((vs, ve, '"Zellij"'))
    else:
        append[DEFAULT_KEY] = '"Zellij"'

    # one combined append for all missing top-level keys
    if append:
        if members:
            last = members[-1]
            ind = indent_of(text, last[1])
            ins = ''.join(',\n' + ind + json.dumps(k) + ': ' + v for k, v in append.items())
            edits.append((last[3], last[3], ins))
        else:
            ins = '\n' + ',\n'.join('    ' + json.dumps(k) + ': ' + v
                                    for k, v in append.items()) + '\n'
            edits.append((root_open + 1, root_open + 1, ins))

    out = text
    for a, b, t in sorted(edits, key=lambda e: e[0], reverse=True):
        out = out[:a] + t + out[b:]

    # Validate before we ever return something to be written.
    result = json.loads(to_strict(out))
    if result.get(PROFILES_KEY, {}).get("Zellij") != PROFILE \
            or result.get(DEFAULT_KEY) != "Zellij":
        raise ValueError("post-edit validation failed")

    changed = out != text
    return out, changed, "updated" if changed else "already configured"


# --- I/O --------------------------------------------------------------------

def default_settings_path():
    if sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Application Support')
    elif os.name == 'nt':
        base = os.environ.get('APPDATA', os.path.expanduser('~'))
    else:
        base = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
    for d in ('Code', 'Code - Insiders', 'VSCodium'):
        p = os.path.join(base, d, 'User', 'settings.json')
        if os.path.isdir(os.path.dirname(p)):
            return p
    return os.path.join(base, 'Code', 'User', 'settings.json')


def manual_block():
    prof = json.dumps({"Zellij": PROFILE}, ensure_ascii=False)
    return ('"%s": %s,\n"%s": "Zellij",' % (PROFILES_KEY, prof, DEFAULT_KEY))


def main(argv):
    path = argv[1] if len(argv) > 1 else default_settings_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path) or not open(path, encoding='utf-8').read().strip():
        text = '{}\n'
        with open(path, 'w', encoding='utf-8') as f:
            f.write(text)
    else:
        with open(path, encoding='utf-8') as f:
            text = f.read()

    try:
        out, changed, note = merge(text)
    except ValueError as e:
        print("!!  Could not safely edit %s (%s)." % (path, e))
        print("    Nothing was changed. Paste this into settings.json manually:\n")
        print(manual_block())
        return 1

    if not changed:
        print("OK  %s (%s)" % (path, note))
        return 0

    backup = "%s.bak.%s" % (path, datetime.now().strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(out)
    print("OK  Updated %s" % path)
    print("    Backup: %s" % backup)
    print("    Reload the VS Code window to pick up the new default profile.")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
