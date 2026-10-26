-- name: runtime
-- description: Non-Apple launchd jobs
-- tables: launchd
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- darwin only: launchd is in osquery's specs/darwin. Linux's counterpart is
-- queries/runtime-linux.sql, and listening ports are queries/ports.sql.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no label appears below (tools/check_no_catalog.py).
--
-- The exclusion is the PLATFORM VENDOR, not a catalog: dropping com.apple.% takes a
-- reference Mac from 937 jobs to 47. Every third-party job ships, because an unrecognised
-- one running unattended is what this branch is for.
SELECT 'daemon' AS kind, label AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM launchd
  WHERE label NOT LIKE 'com.apple.%'
