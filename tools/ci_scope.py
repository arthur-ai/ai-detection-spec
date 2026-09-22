#!/usr/bin/env python3
"""Decide whether a diff can change what the RUNTIME gates measure.

    python3 tools/ci_scope.py <base-ref-or-sha> <head-sha>
    python3 tools/ci_scope.py --paths README.md CLAUDE.md   # for tests

Prints `runtime=true` or `runtime=false` on stdout in GITHUB_OUTPUT form, and a human
sentence on stderr saying which file decided it.

WHAT THIS IS FOR. The scenario matrix installs real software on 26 macOS runners and
bills ten minutes for every job that touches one, however briefly. A pull request that
edits only prose cannot change what osqueryi finds on a Mac, and eleven of the last
thirty pull requests here edited only prose.

IT IS A DENY-LIST, AND THAT DIRECTION IS THE WHOLE SAFETY PROPERTY. An allow-list --
"run when queries/ or catalog/ changed" -- is a list that has to agree with the tree, and
a new directory nobody added to it would be SKIPPED rather than unmatched. That is the
`ext`-missing-from-`KIND_ROUTES` bug in a new place: invisible, and green. So the
question asked here is the other one, `is every changed path documentation`, and anything
unrecognised answers no and runs the suite.

WHY `.md` AND NOTHING ELSE. Every gate that READS a Markdown file -- check_doc_numbers,
check_workflows, agent_status, test_telemetry -- runs in the lint job, and lint is NOT
gated by this: it runs on every pull request as it always has, so documentation drift is
still caught on the commit that causes it. What is gated is the three things that need a
runner with osquery on it, and none of them opens a `.md`. `docs/blind-spots.yaml` is
deliberately NOT treated as documentation despite living under docs/: it is data that
tools/agent_status.py reads, and the coverage gate runs on a runner.

NO DIFF MEANS RUN. A force-push, a new branch, a shallow clone that cannot reach the base
-- every one of them lands here as "cannot tell", and cannot-tell runs the suite. An
empty result must never be indistinguishable from a clean one, which in this file means a
diff nobody could compute must never read as a diff with nothing expensive in it.
"""
import argparse
import subprocess
import sys

# A path is documentation if it matches one of these. Keep it short: every entry is a
# promise that no job gated by this file reads that path, and the promise is checked by
# eye, not by a tool.
DOC_SUFFIXES = (".md",)
DOC_PATHS = ("LICENSE",)


def is_doc(path):
    return path.endswith(DOC_SUFFIXES) or path in DOC_PATHS


def changed(base, head):
    """The paths a diff touches, or None when the diff cannot be computed.

    None is not an empty list and the caller must not treat it as one -- see the module
    docstring. Returned rather than raised because "could not tell" is a normal state
    here (force-push, first push of a branch) rather than an error.
    """
    if not base or set(base) == {"0"}:
        return None
    try:
        out = subprocess.run(["git", "diff", "--name-only", f"{base}...{head}"],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        # Two-dot as a fallback: `a...b` needs a reachable merge base, which a shallow
        # fetch may not have, while `a b` needs only the two commits.
        try:
            out = subprocess.run(["git", "diff", "--name-only", base, head],
                                 capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError as exc:
            print(f"cannot diff {base}..{head}: {exc.stderr.strip()}", file=sys.stderr)
            return None
    return [p for p in out.splitlines() if p]


def decide(paths):
    """(runtime, why). `paths is None` -- no computable diff -- runs the suite."""
    if paths is None:
        return True, "no diff could be computed, so the runtime gates run"
    if not paths:
        return True, "the diff is empty, which is not the same as documentation-only"
    code = [p for p in paths if not is_doc(p)]
    if code:
        shown = ", ".join(sorted(code)[:3])
        more = f" (+{len(code) - 3} more)" if len(code) > 3 else ""
        return True, f"{len(code)} of {len(paths)} changed paths are not documentation: {shown}{more}"
    return False, f"all {len(paths)} changed paths are documentation; lint still runs"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base", nargs="?")
    ap.add_argument("head", nargs="?", default="HEAD")
    ap.add_argument("--paths", nargs="*", default=None,
                    help="decide on this list instead of a git diff (tests)")
    args = ap.parse_args()
    paths = args.paths if args.paths is not None else changed(args.base, args.head)
    runtime, why = decide(paths)
    print(f"runtime={'true' if runtime else 'false'}")
    print(why, file=sys.stderr)


if __name__ == "__main__":
    main()
