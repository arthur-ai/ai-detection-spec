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
SELECT 'file' AS kind, path AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/Users/%/.local/bin/%'
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
