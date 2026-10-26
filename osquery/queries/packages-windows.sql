-- name: packages-windows
-- description: Every npm global package on Windows
-- tables: npm_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- The Windows twin of packages.sql. npm_packages searches C:\Users\%\AppData\Roaming\npm and
-- nvm's directories on Windows (npm_packages.cpp at 5.23.1), so a global prefix moved
-- anywhere else is not read (docs/blind-spots.yaml).
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- The structural predicate is packages.sql's, with Windows separators.
SELECT 'npm' AS kind, name AS id, version AS ver, path AS loc, '' AS extra, '' AS perms
  FROM npm_packages
  WHERE path NOT LIKE '%\node_modules\%\node_modules\%'
