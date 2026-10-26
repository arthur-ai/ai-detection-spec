-- name: packages
-- description: Every npm global package, and every bun global
-- tables: users, file, npm_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py). A
-- name filter here once missed '@google/gemini-cli' and '@github/copilot', which sit
-- outside the vendor scopes it checked.
--
-- The predicate is STRUCTURAL: npm_packages recurses into each global's own node_modules,
-- and dropping nested paths keeps one row per global, on Linux as on macOS.
SELECT 'npm' AS kind, name AS id, version AS ver, path AS loc, '' AS extra, '' AS perms
  FROM npm_packages
  WHERE path NOT LIKE '%/node_modules/%/node_modules/%'
UNION ALL
-- BUN GLOBALS. npm_packages searches npm, nvm, asdf, fnm, mise and volta prefixes and never
-- ~/.bun (npm_packages.cpp at 5.23.1). Its `directory` constraint means "the directory that
-- holds node_modules", pushed down once per home. The homes are queries/browser.sql's, and
-- a `file` directory row ends in '/', so it is trimmed first.
--
-- `extra` IS 'bun' because bun hoists a global's dependencies flat beside it, where the
-- structural predicate cannot drop them: it tells a reader why one global brought several
-- rows. Not covered: BUN_INSTALL_GLOBAL_DIR or bunfig's globalDir.
SELECT 'npm', np.name, np.version, np.path, 'bun', ''
  FROM (SELECT directory AS home FROM users
        UNION
        SELECT rtrim(path, '/') FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') h
       CROSS JOIN npm_packages np ON np.directory = h.home || '/.bun/install/global'
  WHERE np.path NOT LIKE '%/node_modules/%/node_modules/%'
