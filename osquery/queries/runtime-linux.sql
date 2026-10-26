-- name: runtime-linux
-- description: systemd units, with a marker saying whether the unit list could be read
-- tables: systemd_units, file, time
-- min-osquery: 5.10.0
-- cost: slow
-- platform: linux
--
-- systemd_units FAILS SOFT, AND THAT IS WHY THIS FILE HAS TWO BRANCHES. With no reachable
-- system bus it logs to stderr ("Failed to connect to the system dbus"), contributes zero
-- rows, and the statement exits 0 with every other row intact. Nothing downstream reads
-- stderr, so a container or a locked-down host would report "no agent units" in the shape a
-- clean host does. The marker below tells them apart.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no unit name appears below (tools/check_no_catalog.py).
--
-- NO VENDOR EXCLUSION, which is a gap rather than a decision: distro units have no
-- structural mark like macOS's com.apple.%, and `fragment_path` cannot serve, because a
-- vendor's own .deb writes to /usr/lib/systemd/system as the distro does. So it enumerates
-- every loaded unit, and `slow` is measured, not declared: the per-unit D-Bus round trips
-- vary more than fourfold between shared-core VMs (queries/COST.md).
--
-- `unit_file_state` ships in `extra` -- enabled, masked, static -- because a masked unit is
-- a different finding from a running one, and only the reader can weigh that.
--
-- IT REPORTS LOADED UNITS, NOT UNIT FILES, unlike launchd: a unit written and
-- daemon-reloaded did not appear until started. So AN AGENT THAT INSTALLED A UNIT AND HAS
-- NEVER RUN IS INVISIBLE HERE. Its state directory is what finds it
-- (docs/blind-spots.yaml).
SELECT 'unit' AS kind, id AS id, '' AS ver, fragment_path AS loc,
       unit_file_state AS extra, '' AS perms
  FROM systemd_units
UNION ALL
-- THE MARKER, a scan row in the spec's outcome vocabulary, reasoned from the UNIT COUNT:
-- a bus socket with nothing serving it still fails systemd_units, so presence alone would
-- report `ok` against a dead bus (Docker's `wedge` again).
--
--     units > 0            -> ok                  the rows above are real
--     no bus socket        -> absent              nothing to read
--     socket, but 0 units  -> unhealthy:no-units  no real systemd host has none
--
-- The subqueries sit in FROM, not the column list, because test/lint.sh reads a branch's
-- columns as the text between SELECT and the first FROM.
SELECT 'scan' AS kind, 'systemd' AS id, CAST(t.unix_time AS TEXT) AS ver,
       '/run/dbus/system_bus_socket' AS loc,
       CASE WHEN u.n > 0 THEN 'ok'
            WHEN s.n = 0 THEN 'absent'
            ELSE 'unhealthy:no-units' END AS extra,
       '' AS perms
  FROM time t,
       (SELECT COUNT(*) AS n FROM systemd_units) u,
       (SELECT COUNT(*) AS n FROM file
          WHERE path = '/run/dbus/system_bus_socket') s
