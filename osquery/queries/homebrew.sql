-- name: homebrew
-- description: Every Homebrew formula and cask
-- tables: homebrew_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- darwin only: homebrew_packages is in osquery's specs/darwin alone, and one missing table
-- fails a whole composed artifact. Linuxbrew is not a blind spot, because an agent installed
-- there is reachable through its npm, pypi or path route.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- The table covers formulae AND casks. `type` says which, and ships in `extra` so a reader
-- can tell the install route apart. Aliased, as every first arm must be (CLAUDE.md, Traps).
SELECT 'brew' AS kind, name AS id, version AS ver, path AS loc,
       type AS extra, '' AS perms
  FROM homebrew_packages
