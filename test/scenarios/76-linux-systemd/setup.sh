#!/bin/bash
# The Linux counterpart of 60-persistence, and it carries a warning the macOS one does
# not need: THIS SCENARIO IS ON PROBATION ALONGSIDE THE ROUTE IT EXERCISES.
#
# catalog/routes.yaml's systemd_prefixes entry says the route survives only while a real
# agent install produces a unit whose name the VENDOR controls, the way a launchd label
# is. No catalogued agent has been observed doing that on Linux yet. So what this proves
# today is that the QUERY and the MATCHER work -- not that any vendor ships such a unit.
# If the first real install shows unit names are user-chosen, the route goes and this
# scenario goes with it, exactly as `ports` did.
#
# The unit is INERT and never started: ExecStart is /bin/true and nothing enables it.
# 60-persistence takes the same care with its plist.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"

# systemd_units reads the SYSTEM BUS. A container has no PID 1 systemd and no bus, so the
# table returns zero rows -- with the statement still exiting 0, which is exactly why
# queries/runtime-linux.sql emits a kind=scan marker. Skipping here is a fact about the
# container, not about the software: on a GitHub ubuntu-24.04 runner systemd IS PID 1 and
# this runs for real.
[ -S /run/dbus/system_bus_socket ] || { echo "SKIP: no system dbus, so systemd_units cannot be read"; exit 3; }
command -v systemctl >/dev/null 2>&1 || { echo "SKIP: no systemctl"; exit 3; }

sudo_maybe mkdir -p /etc/systemd/system
sudo_maybe tee /etc/systemd/system/ai.openclaw.gateway.service >/dev/null <<'UNIT'
[Unit]
Description=Inert fixture unit for osquery-ai-discovery. Never started.
[Service]
Type=oneshot
ExecStart=/bin/true
UNIT
# Reloaded so systemd knows the unit exists and systemd_units reports it. NOT enabled and
# NOT started.
sudo_maybe systemctl daemon-reload || echo "WARN: daemon-reload failed"

# A listening port, for the `port` branch. Nothing is detected BY port -- the `ports`
# route is retired -- but the rows still ship as evidence and the branch needs exercising.
(setsid nohup sh -c 'exec nc -l 18789' >/dev/null 2>&1 &) || true
sleep 1
