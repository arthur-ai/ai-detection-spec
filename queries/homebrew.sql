-- name: homebrew
-- description: Every Homebrew formula and cask
-- tables: homebrew_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- SPLIT OUT OF packages.sql, which is `posix` now. homebrew_packages is a darwin-only
-- osquery table -- it is in specs/darwin and nowhere else -- so naming it in a composed
-- Linux artifact would make that whole artifact fail on the first table and return
-- "[\n\n]" with exit 1.
--
-- Homebrew does run on Linux and osquery cannot see it there, which is why this route is
-- darwin-only rather than posix. It is not listed as a blind spot: an agent reachable
-- through /home/linuxbrew is reachable through its npm, pypi or path route as well.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No package name appears below.
--
-- homebrew_packages covers BOTH formulae and casks -- it has a `type` column returning
-- 'formula' or 'cask', and cask rows carry a /opt/homebrew/Caskroom/... path. An earlier
-- reading of this was wrong: a scenario installing an ollama formula AND an ollama-app
-- cask returned one row, and we concluded casks were unmodelled rather than checking.
-- `type` ships in `extra` so the collector can tell the install route apart.
--
-- ALIASED, like every first arm must be: a UNION ALL takes its column NAMES from the
-- first arm only, and composition is per platform now, so which file leads an artifact
-- depends on the platform. There is no donor to inherit from.
SELECT 'brew' AS kind, name AS id, version AS ver, path AS loc,
       type AS extra, '' AS perms
  FROM homebrew_packages
