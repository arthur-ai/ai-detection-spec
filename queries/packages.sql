-- name: packages
-- description: Every npm global and every Homebrew formula and cask
-- tables: npm_packages, homebrew_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
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
SELECT 'npm' AS kind, name AS id, version AS ver, path AS loc, '' AS extra, '' AS perms
  FROM npm_packages
  WHERE path NOT LIKE '%/node_modules/%/node_modules/%'
UNION ALL
-- homebrew_packages covers BOTH formulae and casks -- it has a `type` column returning
-- 'formula' or 'cask', and cask rows carry a /opt/homebrew/Caskroom/... path. An earlier
-- reading of this was wrong: a scenario installing an ollama formula AND an ollama-app
-- cask returned one row, and we concluded casks were unmodelled rather than checking.
-- `type` ships in `extra` so the collector can tell the install route apart.
SELECT 'brew', name, version, path, type, '' FROM homebrew_packages
