-- name: vscode
-- description: VS Code extensions, which is how several agents primarily ship
-- tables: users, file, vscode_extensions
-- min-osquery: 5.15.0
-- cost: fast
-- platform: posix
--
-- min-osquery IS 5.15.0, for `vscode_edition`, not 5.11.0, where the table first appears:
-- osqueryi given a column its table lacks fails the statement ("no such column", exit 1,
-- "[\n\n]", measured on 5.23.1), so on 5.11-5.14 this returns nothing rather than ids
-- without an edition. So it stays its own pack entry and composed branch, never folded into
-- a file other branches depend on.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no extension id appears below (tools/check_no_catalog.py). The
-- uid list and the CROSS JOIN are queries/browser.sql's. Without the join the answer is
-- whatever root has installed.
--
-- `name` ALONE IS THE IDENTIFIER: it already holds the marketplace id
-- (`saoudrizwan.claude-dev`). `publisher_id` is a GUID and `publisher` a display name, so
-- `publisher_id || '.' || name` would produce an id that matches nothing. Read off Cline
-- and Continue on osquery 5.23.1.
--
-- `vscode_edition` ships in `extra`: one extension in VS Code, Cursor, Windsurf, VSCodium
-- and Trae is five findings with different blast radii, and only the reader can weigh that.
SELECT 'vscodeext' AS kind, name AS id, version AS ver, path AS loc,
       vscode_edition AS extra, '' AS perms
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN vscode_extensions USING (uid)
