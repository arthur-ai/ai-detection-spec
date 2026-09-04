-- name: runtime
-- description: Non-Apple launchd jobs
-- tables: launchd
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- THE LISTENING-PORT BRANCH MOVED OUT to queries/ports.sql, which is `posix`. It was
-- always portable -- listening_ports and processes exist on every platform -- and leaving
-- it here would have meant a second copy in the Linux file. launchd is what is
-- macOS-only: it is in osquery's specs/darwin, and its Linux counterpart is a different
-- table with different columns and a different failure mode, so that lives in
-- queries/runtime-linux.sql rather than in a widened version of this.
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
