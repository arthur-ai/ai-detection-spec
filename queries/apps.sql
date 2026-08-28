-- name: apps
-- description: Every installed .app bundle
-- tables: apps
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). This branch holds no catalog and names no product.
--
-- It used to carry an IN list of thirteen bundle ids, and that list was wrong in ways
-- that only a real install could reveal. OpenClaw ships 'ai.openclaw.mac', but the design
-- said 'bot.molt.mac', read off the Homebrew cask's zap stanza, which enumerates
-- artifacts to clean up INCLUDING historical ones and is therefore a superset of current
-- identity. Every Mac scanned before that correction reported no OpenClaw, and stayed
-- wrong until it rescanned. A collector that classifies from retained evidence fixes the
-- past instead. A device that filters cannot.
--
-- Cost of enumerating is bounded and measured: see queries/COST.md.
SELECT 'app' AS kind, bundle_identifier AS id, bundle_short_version AS ver, path AS loc,
       '' AS extra, '' AS perms
  FROM apps
