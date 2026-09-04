#!/bin/bash
# THE CONTROL, and the most important scenario in the Linux set for the same reason
# 00-baseline is on macOS: it installs NOTHING and asserts nothing is found.
#
# A detection suite that only ever asserts must_find cannot tell a working matcher from
# one that claims everything. This is the scenario that would fail if a Linux route
# matched on a substring, or if the base OS shipped something a signature wrongly claimed
# -- and Ubuntu genuinely does ship `libxcursor1` and `libwayland-cursor0`, which is the
# `libxdmcp`-versus-`mcp` shape sitting there for free on every Linux box.
set -e
exit 0
