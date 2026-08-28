-- name: runtime
-- description: Non-Apple launchd jobs, and every process holding a listening port
-- tables: launchd, listening_ports, processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No product label and no port number appears below.
--
-- The exclusion is the PLATFORM VENDOR, not a catalog: it drops Apple's own jobs, the
-- same move as excluding the stock iCloud Passwords bridge in browser.sql. Measured on
-- a reference Mac: 937 launchd jobs total, 47 once com.apple.% is dropped. Enumerating
-- all 937 would spend the entire EA budget describing macOS to itself.
--
-- An unrecognised job running unattended is the point of this branch, so the surviving
-- set is deliberately every third party, not an AI shortlist. The old version matched
-- three label prefixes and would have missed any agent that had not been catalogued yet
-- -- which is the whole category this product exists to find.
SELECT 'daemon' AS kind, label AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM launchd
  WHERE label NOT LIKE 'com.apple.%'
UNION ALL
-- Previously an IN list of four inference ports. A local model server on any other port
-- was invisible, and picking the port list on the device means a new runtime is missed
-- until every Mac is redeployed.
--
-- `port > 0` is structural, not selective: listening_ports rows with port 0 are unix
-- domain sockets and non-listening entries, 176 rows down to 34 on the reference Mac.
-- The bind address travels in `extra`, because 0.0.0.0 is a sharply higher-risk finding
-- than loopback and only the collector can weigh that.
SELECT 'port', CAST(lp.port AS TEXT), '', p.path, lp.address, ''
  FROM listening_ports lp JOIN processes p USING (pid)
  WHERE lp.port > 0
