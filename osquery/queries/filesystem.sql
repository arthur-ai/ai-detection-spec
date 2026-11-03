-- name: filesystem
-- description: Home-directory install locations: CLI shims, state dotdirs, tool venvs, model stores
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no agent name appears in any glob below
-- (tools/check_no_catalog.py). `file` has no rows until a path pattern constrains it, so
-- this globs the LOCATIONS a user-installed tool lands in: '~/.local/bin/%' names no
-- product, '~/.local/bin/claude' would.

-- CLI shims, every entry, so an agent nobody has catalogued still arrives.
--
-- `ver` IS THE RELEASE A SHIM RUNS, where a native installer keeps each one as
-- ~/.local/share/<tool>/versions/<version> and links the shim to it, as Claude Code's does.
-- `inode` is stat()'s, so a link reports its target's, and the join finds that file under
-- the same home. Not `symlink_target_path`: it arrived in 5.17.0, and a column the table
-- lacks fails the statement, every other shim with it. Empty for any other shim.
SELECT 'file' AS kind, s.path AS id, coalesce(max(v.ver), '') AS ver, s.path AS loc,
       '' AS extra, '' AS perms
  FROM file s
  LEFT JOIN (SELECT path, inode, regex_match(path, '/versions/([^/]+)$', 1) AS ver
               FROM file
              WHERE path LIKE '/Users/%/.local/share/%/versions/%' AND symlink = 0) v
    ON v.inode = s.inode
   AND substr(v.path, 1, instr(s.path, '/.local/bin/'))
       = substr(s.path, 1, instr(s.path, '/.local/bin/'))
  WHERE s.path LIKE '/Users/%/.local/bin/%'
  GROUP BY s.path
UNION ALL
-- STATE DIRECTORIES, the signal least tied to an install route: a cask, an npm global, a
-- curl installer and a source checkout all create the same dotdir on first run. Every
-- top-level dotdir, so a new agent's is evidence on the first scan.
--
-- THE TRAILING SLASH IS LOAD-BEARING: osquery's glob addresses a directory only with one,
-- and '/Users/%/.claude' returns 0 rows with no error. `.` and `..` come back from this
-- shape and can never match, so they are excluded.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.%/'
    AND path NOT LIKE '%/./'
    AND path NOT LIKE '%/../'
UNION ALL
-- PYTHON-PACKAGED AGENTS. python_packages is too slow to ship (queries/COST.md), and
-- several agents ship on PyPI only, so this globs pipx's and uv's tool directories, each
-- named for its package. bin/classify's tool-dir match reads the name back.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.local/pipx/venvs/%/'
     OR path LIKE '/Users/%/.local/share/uv/tools/%/'
-- KNOWN GAP: a package run through `npx`/`bunx` and never installed. Its cache,
-- ~/.npm/_npx/<hash>/node_modules/<pkg>, cannot tell the invoked package from its
-- dependencies by path (1938 rows on a reference Mac). Such an agent may still be caught
-- by its state dotdir on first run, but that is unverified, so it stays a gap.
