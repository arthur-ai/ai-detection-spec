#!/usr/bin/env python3
"""Check what `bin/discover --names` printed: one line, names then status, in vocabulary.

    test/check_names_line.py --status-file inv.status names.write names.cache names.base

Every file is one line of the form `<names>; <status>`. `<names>` is `none` or a comma
list. `<status>` is the status.txt line, so it is held to that contract: `ok` or
`degraded`, an ISO timestamp, `rows=N`, then `branch=outcome` tokens drawn from the
spec's scan outcomes, read from the evidence schema by test/conformance.py rather than
copied here. With --status-file, the FIRST file's status half must equal that file byte for
byte -- one statement produces both, and this is what proves it.

Lives here rather than inline in ci.yml so the macOS and Linux jobs run the same text.
"""
import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "test"))
from conformance import scan_outcome_ok  # noqa: E402

STAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


def check(path):
    text = open(path).read()
    if text.count("\n") != 1 or not text.endswith("\n"):
        return f"{path}: --names must print exactly one line, got {text!r}"
    left, sep, right = text.rstrip("\n").partition("; ")
    if not sep:
        return f"{path}: no '; ' between the names and the status: {text!r}"
    if left != "none" and not all(p.strip() for p in left.split(",")):
        return f"{path}: names half is neither 'none' nor a list: {left!r}"
    first, stamp, rest = (right.split(maxsplit=2) + ["", ""])[:3]
    if first not in ("ok", "degraded"):
        return f"{path}: status half starts {first!r}, want ok or degraded"
    if not STAMP.fullmatch(stamp):
        return f"{path}: status timestamp is not ISO-8601 UTC: {stamp!r}"
    if not rest.startswith("rows="):
        return f"{path}: status half carries no rows= token: {right!r}"
    if right.endswith(" "):
        return f"{path}: status half has a trailing space: {right!r}"
    for k, v in (p.split("=", 1) for p in rest.split()[1:] if "=" in p):
        if not scan_outcome_ok(v):
            return f"{path}: unknown outcome {v!r} for {k}; the vocabulary must not grow silently"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--status-file", help="status.txt the first file's run also wrote")
    a = ap.parse_args()
    for path in a.files:
        problem = check(path)
        if problem:
            sys.exit(f"::error::{problem}")
    if a.status_file:
        status = open(a.status_file).read().rstrip("\n")
        right = open(a.files[0]).read().rstrip("\n").partition("; ")[2]
        if right != status:
            sys.exit("::error::--names printed a status that differs from the file the "
                     f"same run wrote:\n  {right}\n  {status}")
    print(f"names: {len(a.files)} line(s) well-formed, status half in vocabulary"
          + (", identical to status.txt" if a.status_file else ""))


if __name__ == "__main__":
    main()
