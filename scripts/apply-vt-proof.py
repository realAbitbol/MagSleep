#!/usr/bin/env python3
"""Publishes the VirusTotal proof after a release: the README badge (between
the VT_BADGE markers) and the CHANGELOG proof line for the released version.

Called by .github/workflows/release.yml (the CI release flow) after the
release is published, instead of the old release.sh inline logic.

Usage: apply-vt-proof.py VERSION BADGE LABEL PERMALINK
  - BADGE is the URL-encoded shields.io value, or "" when the verdict is not
    "completed" (the README badge is then left untouched).
  - LABEL is the human verdict (e.g. "0 malicious / 75 engines").
  - PERMALINK is the VirusTotal results URL.
Both edits are idempotent: the CHANGELOG line is not duplicated on re-runs.
"""

import sys


def main() -> int:
    version, badge, label, permalink = sys.argv[1:5]

    if badge:
        path = "README.md"
        s = open(path).read()
        start, end = "<!-- VT_BADGE -->", "<!-- /VT_BADGE -->"
        if start in s and end in s:
            i, j = s.index(start), s.index(end)
            line = (
                f"[![VirusTotal]"
                f"(https://img.shields.io/badge/VirusTotal-{badge}-4c1?logo=virustotal)"
                f"]({permalink})"
            )
            # Idempotent AND self-healing: an identical badge line is left in
            # place, and any different pre-existing badge line is replaced —
            # a re-run may carry a new permalink (a rebuilt DMG has a fresh
            # sha256), so badges must not stack between the markers.
            lines = s[i + len(start):j].splitlines()
            if line in [ln for ln in lines if ln.startswith("[![VirusTotal]")]:
                print("README badge already present — skipping", file=sys.stderr)
            else:
                kept = [ln for ln in lines if not ln.startswith("[![VirusTotal]")]
                inner = "\n".join(kept + [line]).strip("\n")
                open(path, "w").write(s[: i + len(start)] + "\n" + inner + "\n" + s[j:])
        else:
            print("warning: VT_BADGE markers not found in README", file=sys.stderr)

    path = "CHANGELOG.md"
    s = open(path).read()
    hdr = f"## [{version}]"
    line = f"- VirusTotal scan of the DMG: [{label}]({permalink})"
    if hdr in s and line not in s:
        i = s.index(hdr)
        j = s.find("\n## [", i + 1)
        if j == -1:
            j = len(s)
        prefix = s[:j].rstrip("\n")
        suffix = s[j:].lstrip("\n")
        open(path, "w").write(prefix + "\n" + line + "\n\n" + suffix)
    elif line in s:
        print("changelog proof line already present — skipping", file=sys.stderr)
    else:
        print(f"warning: no CHANGELOG section for [{version}]", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
