-- name: jetbrains
-- description: JetBrains IDE plugins, the second editor route Continue and Cline ship through
-- tables: users, file, jetbrains_plugins
-- min-osquery: 5.18.0
-- cost: fast
-- platform: posix
--
-- min-osquery IS 5.18.0, where the table first appears. Older, this query exits 1 with
-- "[\n\n]", so it stays its own pack entry and composed branch (queries/vscode.sql says why).
--
-- THE LINUX DIRECTORY HAS NO plugins/ SUFFIX: osquery reads ~/.local/share/JetBrains/<Product>%
-- on Linux and .../<Product>%/plugins on macOS (jetbrains_plugins.h at 5.23.1), so a plugin
-- unpacked one level deeper on Linux is not seen.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no plugin name appears below (tools/check_no_catalog.py). The uid
-- list and the CROSS JOIN are queries/browser.sql's.
--
-- `id` IS THE LAST PATH COMPONENT: the plugin directory, named for the root of the vendor's
-- zip. A bare-jar plugin's id carries a version, so it is never a catalog value. The
-- plugin.xml id is not a column.
--
-- `extra` IS THE VENDOR, which nothing else in the row carries. It tells a fork named
-- `cline` from Cline. The product is already in `loc`.
SELECT 'jbplugin' AS kind, regex_match(path, '([^/]+)/?$', 1) AS id, version AS ver,
       path AS loc, vendor AS extra, '' AS perms
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN jetbrains_plugins USING (uid)
