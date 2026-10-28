#!/usr/bin/env python3
"""tools-hub secrets guard.

Keeps live credentials out of git objects while leaving the on-disk files
untouched, so the working tree stays fully functional and the repository
stays clean.

Modes
  clean <path>    working tree (real secrets) -> repo blob (placeholders)
  smudge <path>   repo blob (placeholders)    -> working tree (real secrets)
  guard           abort if any *staged* content still holds a credential
  check <path>>   print which patterns match a file (diagnostics)

The clean/smudge modes implement the git filter protocol: content is read
from stdin and the transformed content is written to stdout.  Binary
payloads are passed through untouched.

Two rule sources are consulted:

  patterns.json  generic, regex-only, safe to commit (no secrets inside)
  vault.json     literal secret -> placeholder map, LOCAL ONLY (gitignored)

The vault is applied first so that known secrets get a unique, restorable
placeholder; generic patterns then act as a catch-all safety net.
"""

import json
import os
import re
import subprocess
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
PATTERNS_FILE = os.path.join(BASE, "patterns.json")
VAULT_FILE = os.path.join(BASE, "vault.json")

# Only look at the head of a payload when deciding text vs binary: key
# material and config files never carry a NUL byte up front, and this keeps
# us from slurping huge media files just to classify them.
SNIFF = 8000


# --------------------------------------------------------------------------
# rule loading
# --------------------------------------------------------------------------
def load_patterns():
    """Return [(compiled_regex_bytes, placeholder_bytes), ...]."""
    try:
        with open(PATTERNS_FILE, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for item in raw:
        pattern = item.get("re")
        placeholder = item.get("ph")
        if not pattern or not placeholder:
            continue
        try:
            out.append((re.compile(pattern.encode("utf-8")), placeholder.encode("utf-8")))
        except re.error:
            continue
    return out


def load_pattern_strings():
    """Raw regex strings, for handing to `git grep -E`."""
    try:
        with open(PATTERNS_FILE, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return []
    return [item["re"] for item in raw if item.get("re")]


def load_vault():
    """Return {secret_string: placeholder_string}."""
    try:
        with open(VAULT_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


# --------------------------------------------------------------------------
# transforms
# --------------------------------------------------------------------------
def is_binary(data):
    return b"\x00" in data[:SNIFF]


def clean(data):
    """Strip secrets out of content that is about to become a git object."""
    if is_binary(data):
        return data

    # Longest secret first so that a short value can never pre-empt a longer
    # one that contains it.
    vault = load_vault()
    for secret in sorted(vault, key=len, reverse=True):
        marker = vault[secret].encode("utf-8")
        data = data.replace(secret.encode("utf-8"), marker)

    for regex, placeholder in load_patterns():
        data = regex.sub(placeholder, data)

    return data


def smudge(data):
    """Put real secrets back when a file lands in the working tree."""
    if is_binary(data):
        return data

    vault = load_vault()
    # Longest placeholder first, so overlapping markers restore correctly.
    for secret, marker in sorted(vault.items(), key=lambda kv: len(kv[1]), reverse=True):
        data = data.replace(marker.encode("utf-8"), secret.encode("utf-8"))

    return data


# --------------------------------------------------------------------------
# guard
# --------------------------------------------------------------------------
def guard():
    """Inspect index blobs with Python regexes; errors block publication.

    Never print matched content: diagnostics must not expose credentials.
    Python regexes support the multiline key rule in patterns.json.
    """
    try:
        with open(PATTERNS_FILE, encoding="utf-8") as handle:
            raw = json.load(handle)
        rules = [(item["name"], re.compile(item["re"].encode())) for item in raw]
        with open(VAULT_FILE, encoding="utf-8") as handle:
            vault = json.load(handle)
        if not rules or not isinstance(vault, dict):
            raise ValueError("missing or invalid redaction rules")
        rules += [("local vault", re.compile(re.escape(secret.encode())))
                  for secret in vault if secret]
        ignored = subprocess.check_output(
            ["git", "ls-files", "-ci", "--exclude-standard", "-z"])
        if ignored:
            print("COMMIT BLOCKED: ignored private/runtime paths remain tracked; "
                  "remove them from the index (keep local files).", file=sys.stderr)
            return 1
        entries = subprocess.check_output(["git", "ls-files", "-s", "-z"])
        blobs = []
        for entry in entries.split(b"\0"):
            if not entry:
                continue
            meta, path = entry.split(b"\t", 1)
            mode, sha, stage = meta.split()
            if stage != b"0" or mode == b"160000":
                raise ValueError("unmerged index or unaudited submodule")
            blobs.append((path.decode("utf-8", "replace"), sha))
        packed = subprocess.check_output(
            ["git", "cat-file", "--batch"],
            input=b"".join(sha + b"\n" for _, sha in blobs))
        offset = 0
        hits = []
        for path, sha in blobs:
            end = packed.index(b"\n", offset)
            header = packed[offset:end].split()
            if len(header) != 3 or header[1] != b"blob":
                raise ValueError("cannot read staged blob")
            size = int(header[2])
            data = packed[end + 1:end + 1 + size]
            offset = end + size + 2
            for name, regex in rules:
                if regex.search(data):
                    hits.append((path, name))
        for path, name in hits[:25]:
            print("COMMIT BLOCKED: %s (rule: %s)" % (path, name), file=sys.stderr)
        return 1 if hits else 0
    except (OSError, ValueError, KeyError, TypeError, re.error,
            subprocess.CalledProcessError) as exc:
        print("COMMIT BLOCKED: credential inspection failed (%s)" %
              type(exc).__name__, file=sys.stderr)
        return 1


def check(path):
    """Diagnostics: show which rules fire on a file."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        print("cannot read %s: %s" % (path, exc), file=sys.stderr)
        return 1

    if is_binary(data):
        print("%s: binary, skipped" % path)
        return 0

    found = False
    for secret in sorted(load_vault(), key=len, reverse=True):
        if secret.encode("utf-8") in data:
            print("%s: vault hit (%d chars)" % (path, len(secret)))
            found = True
    for regex, placeholder in load_patterns():
        for match in regex.finditer(data):
            print("%s: pattern %s -> %s"
                  % (path, match.group()[:24].decode("utf-8", "replace"),
                     placeholder.decode("utf-8")))
            found = True
    if not found:
        print("%s: clean" % path)
    return 0


# --------------------------------------------------------------------------
def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    mode = argv[1]

    if mode == "clean":
        sys.stdout.buffer.write(clean(sys.stdin.buffer.read()))
        return 0

    if mode == "smudge":
        sys.stdout.buffer.write(smudge(sys.stdin.buffer.read()))
        return 0

    if mode == "guard":
        return guard()

    if mode == "check":
        return check(argv[2]) if len(argv) > 2 else 2

    print("unknown mode: %s" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
