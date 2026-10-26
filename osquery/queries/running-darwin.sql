-- name: running-darwin
-- description: Running app bundles by bundle id, the macOS half of "installed and running"
-- tables: processes, plist
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- LIVENESS for agents that ship as an .app. The id comes from the bundle's own Info.plist,
-- so the running_apps route reads bundle_ids' values and needs none of its own.
--
-- NOT A JOIN ON `apps`: osquery regenerates that table per outer row and takes no path
-- constraint, so a join did not finish in 120s on a 414-app Mac. `plist` takes a path.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no bundle id appears below (tools/check_no_catalog.py).
--
-- THE OUTERMOST BUNDLE, through instr() on the first '.app/': a helper inside its host
-- (<app>/Contents/Frameworks/<X> Helper.app) has an id no catalog value names, so it folds
-- into its host, and the inner DISTINCT folds the host's processes into one row. No outer
-- DISTINCT, because lint and tools/build.py find a branch's kind as `SELECT '<kind>'`.
SELECT 'proc' AS kind, pl.value AS id, '' AS ver, x.app AS loc, '' AS extra, '' AS perms
  FROM (SELECT DISTINCT substr(path, 1, instr(path, '.app/') + 3) AS app
          FROM processes WHERE path LIKE '%.app/Contents/MacOS/%') x
       CROSS JOIN plist pl ON pl.path = x.app || '/Contents/Info.plist'
  WHERE pl.key = 'CFBundleIdentifier'
