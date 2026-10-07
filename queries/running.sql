-- name: running
-- description: Running node packages by name, the npm half of "installed and running"
-- tables: processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- LIVENESS. Every other posix branch reports presence. A `proc` row says the package is
-- RUNNING now, which the retired `ports` route was never able to say on its own: a port
-- is only attributable when the process holding it already names the agent.
--
-- `cmdline` IS NEVER EMITTED. It can carry --api-key or a session token, so only a
-- package name extracted from it leaves the machine, and only when the pattern matches.
-- `loc` is the executable's path.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.

-- ENUMERATE, DO NOT MATCH (D20). No package name appears below.
--
-- TWO SHAPES, AND ONLY TWO. A native binary shipped inside a package runs from its
-- node_modules path. A JS entry point runs under node, bun or deno with the script as an
-- argument. A shell whose command line merely mentions a node_modules path is NOT that
-- package running, and an unrestricted cmdline match reported exactly that on the machine
-- this was written on.
--
-- THE RUNTIME IS READ OFF THE EXECUTABLE, NOT `name`. Node renames its processes:
-- OpenClaw's gateway reports `openclaw-gateway` and its workers `MainThread`, with path
-- /usr/bin/node and a worker script under node_modules/openclaw. Read off a running
-- gateway in an Ubuntu 24.04 container on 2026-10-07.
--
-- WHEN `path` IS EMPTY, argv[0] STANDS IN. Reading another user's executable link needs
-- ptrace rights, which a non-root reader and root in a default Docker container both lack:
-- the same gateway, run as an ordinary user, came back with path ''. Only argv[0] is taken
-- from the command line for this, and it decides nothing beyond "is this a runtime".
--
-- THE NAME IS npm's CHARACTER SET, so `node_modules/.bin/<shim>`, which is how npx runs
-- things, matches nothing: a shim name is not a package name. The same class is why this
-- query's own text cannot match itself when it is passed on a command line.
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
