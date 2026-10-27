-- name: vscode-windows
-- description: VS Code extensions on Windows, which is how several agents primarily ship
-- tables: users, vscode_extensions
-- min-osquery: 5.15.0
-- cost: fast
-- platform: windows
--
-- The Windows twin of vscode.sql, whose comments explain the floor, the identifier and
-- `extra`. The uid list is browser-windows.sql's.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- `path` comes back URI-shaped on Windows (`/c:/Users/<u>/.vscode/extensions/...`). It ships
-- in `loc` only, and no route compares it.
SELECT 'vscodeext' AS kind, name AS id, version AS ver, path AS loc,
       vscode_edition AS extra, '' AS perms
  FROM (SELECT uid FROM users) u
       CROSS JOIN vscode_extensions USING (uid)
