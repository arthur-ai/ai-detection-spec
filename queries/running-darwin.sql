-- name: running-darwin
-- description: Running app bundles by bundle id, the macOS half of "installed and running"
-- tables: processes, plist
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- LIVENESS, for the agents that ship as an .app. The id is the bundle id from the
-- bundle's own Info.plist, so the running_apps route reads the same catalog values as
-- bundle_ids and a running app needs no second signature.
--
-- NOT A JOIN ON `apps`. osquery regenerates that table for every outer row and it takes
-- no path constraint: measured 2026-10-07 with 414 apps and 913 processes, a LIKE join did
-- not finish in 120s and an equality join took 42s. `plist` does take a path, so this
-- reads one Info.plist per running bundle, 0.3s on the same machine.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.

-- ENUMERATE, DO NOT MATCH (D20). No bundle id appears below.
--
-- THE OUTERMOST BUNDLE, through instr() on the first '.app/'. A helper lives inside its
-- host, at <app>/Contents/Frameworks/<X> Helper.app, and carries an id of its own that no
-- catalog value names. Taking the outermost bundle folds every helper into its host, and
-- the inner DISTINCT folds the host's processes into one row. The outer SELECT carries no
-- DISTINCT because lint and tools/build.py find a branch's kind as `SELECT '<kind>'`.
SELECT 'proc' AS kind, pl.value AS id, '' AS ver, x.app AS loc, '' AS extra, '' AS perms
  FROM (SELECT DISTINCT substr(path, 1, instr(path, '.app/') + 3) AS app
          FROM processes WHERE path LIKE '%.app/Contents/MacOS/%') x
       CROSS JOIN plist pl ON pl.path = x.app || '/Contents/Info.plist'
  WHERE pl.key = 'CFBundleIdentifier'
