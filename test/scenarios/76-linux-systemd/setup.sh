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
Description=Inert fixture unit for osquery-ai-discovery. Runs /bin/true and nothing else.
[Service]
Type=oneshot
ExecStart=/bin/true
# So the unit stays LOADED after its one command exits -- see the note below on why that
# is the difference between this scenario passing and proving nothing.
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
try "systemctl daemon-reload" sudo_maybe systemctl daemon-reload || true

# WRITING THE FILE IS NOT ENOUGH, AND THAT IS THE FINDING THIS SCENARIO PRODUCED.
#
# The first CI run of this asserted on a unit that was written, reloaded, and never
# started -- exactly what 60-persistence does with its macOS plist. It failed:
# systemd_units returned 477 rows and none of them was this unit.
#
# THE TWO TABLES ARE NOT THE SAME SHAPE. `launchd` READS THE PLIST FILES on disk, so an
# inert, never-loaded job is visible there. `systemd_units` asks the running MANAGER for
# its loaded units, so a unit file nobody has loaded does not exist as far as it is
# concerned. The macOS scenario's "inert" is genuinely inert; the Linux one has to be
# loaded to be seen at all.
#
# So it is started -- and `ExecStart=/bin/true` means "started" costs one process that
# exits immediately and does nothing. It is still never enabled at boot, and nothing about
# the machine changes. `RemainAfterExit=yes` keeps it loaded rather than letting systemd
# garbage-collect a dead oneshot mid-run, which would make this flaky rather than wrong.
#
# The consequence for real detection is recorded in docs/blind-spots.yaml: an agent that
# installs a unit and has never run is invisible on this route, and its state directory is
# what would find it.
try "systemctl start of the inert unit" \
  sudo_maybe systemctl start ai.openclaw.gateway.service || true
systemctl is-active ai.openclaw.gateway.service 2>&1 | head -1 || true
echo "--- does the manager report it?"
systemctl list-units --all --no-legend 'ai.openclaw.*' 2>&1 | head -3 \
  || echo "WARN: the manager does not list the unit, so systemd_units will not either"

# A listening port, for the `port` branch. Nothing is detected BY port -- the `ports`
# route is retired -- but the rows still ship as evidence and the branch needs exercising.
#
# python3, NOT nc. The Debian 12 and Rocky 9 Compute Engine images ship no netcat at all,
# so `nc -l` failed silently there and the port assertion was the only thing that said
# so. python3 is already a prerequisite of every assertion, so it is the one listener
# every host this runs on is guaranteed to have.
(setsid nohup python3 -m http.server 18789 --bind 127.0.0.1 >/dev/null 2>&1 &) || true
sleep 1
