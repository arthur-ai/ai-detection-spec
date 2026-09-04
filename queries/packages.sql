-- name: packages
-- description: Every npm global package
-- tables: npm_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- POSIX, AND THE HOMEBREW BRANCH MOVED OUT to queries/homebrew.sql. npm_packages is
-- cross-platform, and homebrew_packages is in osquery's specs/darwin and nowhere else,
-- so one file could not carry both once a Linux artifact had to be composed. The branches
-- are EXTRACTED rather than copied: two npm branches in two files would be two things to
-- keep in step, which is the drift this repo spends its comments preventing.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No package name appears below.
--
-- The name filter this replaces missed '@google/gemini-cli' and '@github/copilot',
-- because they sit under vendor scopes rather than the '@anthropic-ai/' and '@openai/'
-- globs it did check. That is the failure mode of a catalog on the device: it is wrong
-- in exactly the places nobody thought to look, and silent about it.
--
-- The remaining predicate is STRUCTURAL, not a catalog. npm_packages recurses into each
-- global's own node_modules, so a machine with seven globals returns 883 rows without it.
-- IT EARNS ITS PLACE ON LINUX TOO, measured in an Ubuntu 24.04 container with one global
-- installed: 329 rows unbounded, 1 with the predicate. The global prefix there is
-- /usr/local/lib/node_modules, and no path in the query depends on that.
SELECT 'npm' AS kind, name AS id, version AS ver, path AS loc, '' AS extra, '' AS perms
  FROM npm_packages
  WHERE path NOT LIKE '%/node_modules/%/node_modules/%'
