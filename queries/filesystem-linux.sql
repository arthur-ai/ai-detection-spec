-- name: filesystem-linux
-- description: Home-directory install locations on Linux: CLI shims, state dotdirs, tool venvs
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- THE LINUX TWIN OF filesystem.sql, and it is a separate file rather than a widened one
-- because these are `file` path globs and there is no way to write a path that is both
-- /Users/%/ and /home/%/. The catalog is unaffected: a signature says `~/.claude` and
-- bin/classify's HOME_ROOTS resolves that against every platform's roots at once.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No agent name appears in any glob below.
--
-- /root IS ITS OWN BRANCH IN EVERY CASE, and that is not tidiness. Root's home is not
-- under /home -- `users.directory` returns /root for uid 0 on both Ubuntu and Fedora --
-- so a `/home/%/` glob cannot reach it and would say nothing about having missed it. An
-- agent installed by a root shell, which is how a good deal of Linux tooling arrives, is
-- exactly what that silence would hide.
--
-- The system accounts are not a concern: their home directories are /usr/sbin,
-- /var/www, /nonexistent and the like, so anchoring on /home/ and /root/ selects real
-- users without needing to know anything about them.

-- CLI shims. Every entry, not a pinned filename, so an agent nobody has catalogued yet
-- still arrives as evidence.
SELECT 'file' AS kind, path AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/home/%/.local/bin/%'
     OR path LIKE '/root/.local/bin/%'
UNION ALL
-- STATE DIRECTORIES, the most install-route-independent signal available: a distro
-- package, an npm global, `curl install.sh | bash` and a source checkout all converge on
-- the same dotdir the first time the agent runs. Package-manager branches see only the
-- route that was used, and see nothing at all for a source build.
--
-- THE TRAILING SLASH IS LOAD-BEARING, on Linux exactly as on macOS. osquery translates
-- LIKE into its glob engine, where a directory must be addressed with a trailing slash:
--     path LIKE '/home/%/.claude'   -> 0 rows, no error
--     path LIKE '/home/%/.claude/'  -> the directory
-- Do not "tidy" the slash away.
--
-- `.` AND `..` COME BACK FROM THIS GLOB SHAPE and are excluded structurally. Measured in
-- an Ubuntu container and then confirmed on a reference Mac, where 4 of the 47 dotdir
-- rows were /Users/x/./ and /Users/x/../ -- so this is a pre-existing wart found on Linux
-- and fixed in both files, not a Linux quirk. They are payload that can never match and
-- they arrive as unmatched rows a reader has to dismiss by hand.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE (path LIKE '/home/%/.%/' OR path LIKE '/root/.%/')
    AND path NOT LIKE '%/./'
    AND path NOT LIKE '%/../'
UNION ALL
-- PYTHON-PACKAGED AGENTS. python_packages is deliberately absent here for the same
-- reason it is absent on macOS -- 15.6s with no WHERE push-down -- so glob the INSTALL
-- LOCATIONS instead. pipx and uv each give a tool its own directory named for the
-- package, which is precise, bounded and free, and bin/classify's TOOL_DIR bridge is
-- what turns that path back into a package name.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.local/pipx/venvs/%/'
     OR path LIKE '/home/%/.local/share/uv/tools/%/'
     OR path LIKE '/root/.local/pipx/venvs/%/'
     OR path LIKE '/root/.local/share/uv/tools/%/'
-- KNOWN GAP, deliberately not covered, and the same one macOS has: packages executed via
-- `npx`/`bunx` and never installed land in a content-addressed cache where the invoked
-- package is indistinguishable BY PATH from its transitive dependencies.
