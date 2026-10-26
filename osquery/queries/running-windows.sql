-- name: running-windows
-- description: Running node packages by name, and agents running from a home directory, on Windows
-- tables: processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- The Windows twin of running.sql, whose comments explain both shapes. `cmdline` is never
-- emitted: only a package name extracted from it leaves the machine.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- THE NAME IS WRITTEN WITH `/`, the form the npm route compares (SPEC.md 5.1): a scoped
-- package runs from node_modules\@scope\name, so the separator inside the name is replaced.
--
-- NO argv[0] FALLBACK: osquery runs as SYSTEM here and reads every process's path. And
-- `path` is the on-disk spelling even when the launcher typed it in lower case or through
-- `\\?\`. Only a launch through an 8.3 short name keeps that name (C:\PROGRA~1\...), which
-- no value matches (survey run 40393754308, docs/blind-spots.yaml).
SELECT 'proc' AS kind,
       replace(regex_match(path || ' ' || cmdline,
                           'node_modules[\\/]((?:@[A-Za-z0-9][A-Za-z0-9._-]*[\\/])?[A-Za-z0-9][A-Za-z0-9._-]*)', 1),
               '\', '/') AS id,
       '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM processes
  WHERE (path LIKE '%\node_modules\%'
         OR ((path LIKE '%\node.exe' OR path LIKE '%\bun.exe' OR path LIKE '%\deno.exe')
             AND cmdline LIKE '%node_modules%'))
    AND regex_match(path || ' ' || cmdline,
                    'node_modules[\\/]((?:@[A-Za-z0-9][A-Za-z0-9._-]*[\\/])?[A-Za-z0-9][A-Za-z0-9._-]*)', 1) IS NOT NULL
  GROUP BY id, loc
UNION ALL
-- RUNNING FROM A HOME DIRECTORY, by executable path, as in running.sql.
SELECT 'proc', path, '', path, '', ''
  FROM processes
  WHERE path LIKE '_:\Users\%\%'
  GROUP BY path
