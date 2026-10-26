-- name: running
-- description: Running node packages by name, and agents running from a home directory
-- tables: processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- LIVENESS: a `proc` row says the agent is running now, where every other posix branch
-- reports presence.
--
-- `cmdline` IS NEVER EMITTED. It can carry --api-key or a session token, so only a package
-- name extracted from it leaves the machine. `loc` is the executable's path.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- TWO SHAPES, AND ONLY TWO: a native binary running from a node_modules path, or node, bun
-- or deno running a script under one. A shell whose command line merely mentions a
-- node_modules path is not that package running.
--
-- THE RUNTIME IS READ OFF THE EXECUTABLE, NOT `name`, because node renames its processes:
-- OpenClaw's gateway reports `openclaw-gateway` and its workers `MainThread`.
--
-- WHEN `path` IS EMPTY, argv[0] STANDS IN. Reading another user's executable link needs
-- ptrace rights, which a non-root reader and root in a default container lack. argv[0]
-- decides only "is this a runtime".
--
-- THE NAME IS npm's CHARACTER SET, so a `node_modules/.bin/<shim>` (how npx runs things)
-- matches nothing, and neither does this query's own text on a command line.
SELECT 'proc' AS kind,
       regex_match(exe || ' ' || cmdline,
                   'node_modules/((?:@[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*)', 1) AS id,
       '' AS ver, exe AS loc, '' AS extra, '' AS perms
  FROM (SELECT cmdline,
               CASE WHEN path != '' THEN path
                    ELSE substr(cmdline, 1, instr(cmdline || ' ', ' ') - 1) END AS exe
          FROM processes) p
  WHERE (exe LIKE '%/node_modules/%'
         OR ((exe LIKE '%/node' OR exe LIKE '%/nodejs' OR exe LIKE '%/bun' OR exe LIKE '%/deno'
              OR exe IN ('node', 'nodejs', 'bun', 'deno'))
             AND cmdline LIKE '%node_modules/%'))
    AND regex_match(exe || ' ' || cmdline,
                    'node_modules/((?:@[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*)', 1) IS NOT NULL
  -- One row per package and executable, however many workers it runs. GROUP BY rather than
  -- DISTINCT, because lint and tools/build.py find a branch's kind as `SELECT '<kind>'`.
  GROUP BY id, loc
UNION ALL
-- RUNNING FROM A HOME DIRECTORY, by executable path: Claude Code's native install runs from
-- ~/.local/share/claude/versions/<version>, not the ~/.local/bin/claude link `binaries`
-- names, so process_paths carries its own value. `path` only: an unreadable path leaves
-- argv[0], the launcher a user typed, which no value names.
SELECT 'proc', path, '', path, '', ''
  FROM processes
  WHERE path LIKE '/Users/%/%' OR path LIKE '/home/%/%' OR path LIKE '/root/%'
  GROUP BY path
