-- name: ports
-- description: Every process holding a listening port
-- tables: listening_ports, processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- SPLIT OUT OF runtime.sql, unchanged, because it is portable and its macOS neighbour is
-- not. listening_ports and processes are cross-platform.
--
-- A PORT IS NOT A SIGNATURE and these rows are not expected to produce findings. The
-- `ports` route is RETIRED -- catalog/agents.yaml's header has the measurement -- because
-- a port only ever matched once the process holding it already named the agent, which
-- makes it a second opinion from the same witness. The rows still ship as raw evidence:
-- an unrecognised process listening unattended is a question worth a reader's time even
-- when nothing can name it.
--
-- The kind stays REGISTERED in catalog/routes.yaml for that reason. A kind absent from
-- the registry is dropped by bin/classify rather than reported unmatched, so retiring the
-- route by deleting it would have made these rows invisible instead of unclaimed -- the
-- `ext` bug, on purpose.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- Previously an IN list of four inference ports. A local model server on any other port
-- was invisible, and picking the port list on the device means a new runtime is missed
-- until every Mac is redeployed.
--
-- `port > 0` is structural, not selective: listening_ports rows with port 0 are unix
-- domain sockets and non-listening entries, 176 rows down to 34 on the reference Mac.
-- The bind address travels in `extra`, because 0.0.0.0 is a sharply higher-risk finding
-- than loopback and only the collector can weigh that.
-- ALIASED: this is a file's first arm now, and a UNION ALL takes its column names
-- from the first arm alone.
SELECT 'port' AS kind, CAST(lp.port AS TEXT) AS id, '' AS ver, p.path AS loc,
       lp.address AS extra, '' AS perms
  FROM listening_ports lp JOIN processes p USING (pid)
  WHERE lp.port > 0
