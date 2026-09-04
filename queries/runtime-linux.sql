-- name: runtime-linux
-- description: systemd units, with a marker saying whether the unit list could be read
-- tables: systemd_units, file, time
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- systemd_units FAILS SOFT, AND THAT IS THE WHOLE REASON THIS FILE HAS TWO BRANCHES.
--
-- With no reachable system bus the table logs to stderr, contributes ZERO rows, and the
-- statement still exits 0 and returns every other row in the artifact. Measured in a
-- container: 0 units, exit 0, 131 rows from the other branches, and this on stderr --
--
--     E systemd_units.cpp:38] Failed to generate the systemd unit list: Failed to
--     connect to the system dbus: ... No such file or directory
--
-- Nothing downstream reads stderr. So a container, a chroot, a minimal image or a host
-- where osquery cannot reach the bus reports "no agent units" in EXACTLY the shape a
-- clean host does -- an empty result indistinguishable from a clean machine, which is the
-- one error this repo exists to avoid. The marker below is the difference between them.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No unit name appears below.
--
-- NO VENDOR EXCLUSION, and that is a gap rather than a decision. macOS drops
-- `com.apple.%` -- 937 launchd jobs down to 47 -- because Apple's own jobs are named
-- after the platform vendor. Linux has no equivalent: the distro's units are named
-- `sshd.service` and `cron.service` with nothing structural to key on. `fragment_path`
-- IS the honest discriminator -- /etc/systemd/system is where locally-installed units
-- land, /usr/lib/systemd/system is where a package puts them -- but a vendor's own .deb
-- also writes to /usr/lib, so filtering on it would drop exactly the packaged agent this
-- branch is for.
--
-- SO IT ENUMERATES EVERYTHING AND THE ROW COUNT IS UNMEASURED. There was no systemd host
-- to measure on: a container has no system bus, which is what the marker below exists to
-- report. tools/measure.py in the Linux CI job is what will produce the number, and if it
-- is large the filter decision gets made then, against evidence. Declaring `fast` here is
-- an expectation, not a measurement, and this comment is the record of which.
--
-- `unit_file_state` ships in `extra` -- enabled, masked, static -- because an installed
-- but masked unit is a materially different finding from a running one, and only the
-- collector can weigh that.
SELECT 'unit' AS kind, id AS id, '' AS ver, fragment_path AS loc,
       unit_file_state AS extra, '' AS perms
  FROM systemd_units
UNION ALL
-- THE MARKER, in the vocabulary bin/classify already understands: `ok` is provenance and
-- anything else becomes a gap the reader is told about rather than a silence.
--
-- SOCKET PRESENCE ALONE IS NOT ENOUGH, and finding that out is what shaped this. Checking
-- only for the bus socket reports `ok` against a socket that exists but has nothing
-- serving it -- reproduced by binding one and watching systemd_units still fail with
-- `Connection refused ... NoServer`. That is precisely the Docker `wedge` state this repo
-- already documents: a health check is necessary and not sufficient.
--
-- So the marker reasons from the UNIT COUNT first, which is the only evidence that
-- actually proves the bus was read:
--
--     units > 0            -> ok         we read the list, so the rows above are real
--     no bus socket        -> absent     nothing to read from, and we know why
--     socket, but 0 units  -> unhealthy  the socket is there and the list came back
--                                        empty, which no real systemd host does
--
-- A host with systemd genuinely has hundreds of units, so zero-with-a-socket is a failure
-- and never a clean machine. Computed entirely in SQL: no runner change, and it travels
-- with a cached payload the same way the container marker does.
--
-- THE SUBQUERIES ARE IN THE FROM CLAUSE, NOT THE COLUMN LIST, and that is deliberate:
-- test/lint.sh reads a branch's columns as the text between SELECT and the first FROM, so
-- a subquery in the column list would truncate the count and the contract check would
-- pass a five-column arm.
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
