-- name: jetbrains
-- description: JetBrains IDE plugins, the second editor route Continue and Cline ship through
-- tables: users, file, jetbrains_plugins
-- min-osquery: 5.18.0
-- cost: fast
-- platform: posix
--
-- min-osquery IS 5.18.0: the spec is absent at 5.17.0 and present at 5.18.0. On an older
-- endpoint this query returns "[\n\n]" and exits 1, so it stays its own pack entry and its
-- own composed branch, for the reason queries/vscode.sql gives.
--
-- THE LINUX DIRECTORY HAS NO plugins/ SUFFIX. osquery reads
-- ~/.local/share/JetBrains/<Product>% on Linux and .../<Product>%/plugins on macOS
-- (jetbrains_plugins.h at 5.23.1). A plugin unpacked one level deeper on Linux is not seen.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.

-- ENUMERATE, DO NOT MATCH (D20). No plugin name appears below.
--
-- The uid list and the CROSS JOIN are queries/vscode.sql's, for the reason given there.
--
-- `id` IS THE LAST PATH COMPONENT. For a plugin shipped as a directory with lib/*.jar,
-- `path` is that directory, and its name is the root of the vendor's zip. For a plugin
-- shipped as a bare jar, `path` is the jar and the id carries a version, so it is never a
-- catalog value. The plugin.xml id is not a column.
--
-- `extra` IS THE VENDOR. The product (IdeaIC2025.2, PyCharm...) is already in `loc`, while
-- the vendor is nowhere else in the row, and it tells a fork named `cline` from Cline.
SELECT 'jbplugin' AS kind, regex_match(path, '([^/]+)/?$', 1) AS id, version AS ver,
       path AS loc, vendor AS extra, '' AS perms
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN jetbrains_plugins USING (uid)
