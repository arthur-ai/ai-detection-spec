-- name: filesystem-windows
-- description: Home-directory install locations on Windows: CLI shims, state dotdirs, tool venvs
-- tables: users, file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- The Windows twin of filesystem.sql, whose comments explain each branch.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no agent name appears in any glob below
-- (tools/check_no_catalog.py).
--
-- THE HOMES COME FROM `users`, NOT A C:\Users\% GLOB. osquery pushes `f.path LIKE
-- u.directory || ...` down once per home, so a profile on any drive is read and the Default
-- template profile is not. `_:\Users\%` is SPEC.md 6.4.7's root: a profile anywhere else
-- could not match a `~/` value. Windows `users` reads the ProfileList, so an account that has
-- signed in once is here whether or not it is signed in now.
--
-- A Windows glob returns a directory with a trailing `\` whether the pattern ends in one or
-- not, and never `.` or `..`, so neither POSIX guard is needed here. The literal part of a
-- path comes back in the pattern's own case, which is why `\Users\` is written as SPEC.md
-- compares it. All measured on windows-2025, osquery 5.23.1 (survey run 40393754308).
SELECT 'file' AS kind, f.path AS id, '' AS ver, f.path AS loc, '' AS extra, '' AS perms
  FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\.local\bin\%'
 WHERE u.directory LIKE '_:\Users\%'
UNION ALL
SELECT 'file', f.path, '', f.path, '', ''
  FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\.%\'
 WHERE u.directory LIKE '_:\Users\%'
UNION ALL
-- PYTHON-PACKAGED AGENTS, through the tool directories pipx and uv make on Windows by default
-- (`pipx environment`, `uv tool dir`), each named for its package. bin/classify's tool-dir
-- match reads the name back (SPEC.md 6.4.6).
SELECT 'file', f.path, '', f.path, '', ''
  FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\AppData\Local\pipx\pipx\venvs\%\'
 WHERE u.directory LIKE '_:\Users\%'
UNION ALL
SELECT 'file', f.path, '', f.path, '', ''
  FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\AppData\Roaming\uv\tools\%\'
 WHERE u.directory LIKE '_:\Users\%'
