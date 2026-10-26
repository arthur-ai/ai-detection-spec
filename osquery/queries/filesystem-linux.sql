-- name: filesystem-linux
-- description: Home-directory install locations on Linux: CLI shims, state dotdirs, tool venvs
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- The Linux twin of filesystem.sql, whose comments explain each branch. A path glob cannot
-- be both /Users/%/ and /home/%/, and the catalog's `~/` values match either (bin/classify).
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no agent name appears in any glob below
-- (tools/check_no_catalog.py).
--
-- /root IS ITS OWN BRANCH IN EVERY CASE: root's home is not under /home, so a /home/%/
-- glob would miss an agent installed from a root shell without saying so. System accounts
-- have homes like /usr/sbin and /nonexistent, so anchoring on /home/ and /root/ selects
-- real users.

-- CLI shims, every entry.
SELECT 'file' AS kind, path AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/home/%/.local/bin/%'
     OR path LIKE '/root/.local/bin/%'
UNION ALL
-- STATE DIRECTORIES. The trailing slash is load-bearing, and `.` and `..` are excluded,
-- as in filesystem.sql.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE (path LIKE '/home/%/.%/' OR path LIKE '/root/.%/')
    AND path NOT LIKE '%/./'
    AND path NOT LIKE '%/../'
UNION ALL
-- PYTHON-PACKAGED AGENTS, through pipx's and uv's tool directories, as in filesystem.sql.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.local/pipx/venvs/%/'
     OR path LIKE '/home/%/.local/share/uv/tools/%/'
     OR path LIKE '/root/.local/pipx/venvs/%/'
     OR path LIKE '/root/.local/share/uv/tools/%/'
-- KNOWN GAP: `npx`/`bunx` runs, as in filesystem.sql.
