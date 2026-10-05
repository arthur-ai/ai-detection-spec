-- name: vscode
-- description: VS Code extensions, which is how several agents primarily ship
-- tables: users, file, vscode_extensions
-- min-osquery: 5.11.0
-- cost: fast
-- platform: posix
--
-- THIS RETIRES A BLIND SPOT RATHER THAN ADDING ONE. docs/blind-spots.yaml said "VS Code
-- extensions -- osquery has no table for them at all". That was true when it was written
-- and is false now: vscode_extensions arrived in osquery 5.11.0. An agent shipping as an
-- extension was invisible on every route, and Cline ships that way first.
--
-- min-osquery IS 5.11.0, ABOVE THE 5.10.0 EVERY OTHER QUERY DECLARES, and this file is
-- why the bound is per-query rather than one number for the repo. Checked against the
-- osquery source tree at both tags: the spec is absent at 5.10.0 and present at 5.11.0.
-- On a 5.10.x endpoint this query is the one that returns "[\n\n]" and exits 1, so it
-- must stay its own pack entry and its own composed branch -- never folded into a file
-- that other branches depend on.
--
-- `vscode_edition` arrived later still, in 5.15.0, so between the two versions this
-- query loses the edition and keeps the identifier. That is the right way round.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No extension id appears below.
--
-- CROSS JOIN is mandatory, the same as chrome_extensions: osquery needs the uid
-- constraint pushed into a user-scoped table, and it says so itself if you forget --
-- "The vscode_extensions table returns data based on the current user by default".
-- Without it the answer is whatever root has installed, which is nothing.
--
-- THE UID LIST IS `users` PLUS THE HOME DIRECTORIES ON DISK, the same shape as
-- queries/browser.sql and for the reason given there: on Linux since osquery 5.13.1 an
-- unconstrained `users` is /etc/passwd, so an OS Login, SSSD or LDAP account is not in
-- it, while a lookup by uid still reaches NSS. Keep the two files' uid source identical.
--
-- `name` ALONE IS THE IDENTIFIER, and reading that off a real install is what stopped a
-- wrong one shipping here. The obvious expression is `publisher_id || '.' || name`, and it
-- is wrong twice over: `name` ALREADY holds the full marketplace id
-- (`saoudrizwan.claude-dev`), and `publisher_id` is a GUID, not a slug --
-- 6f42e67d-d7ea-4a53-8704-2ae8bf2d86f3 for Cline. That expression would have produced
-- `6f42e67d-....saoudrizwan.claude-dev`: an identifier that matches nothing, in a column
-- that looks deliberate. `publisher` is a display name ("Cline"), not an id either.
-- Verified 2026-09-04 on osquery 5.23.1 against Cline 4.1.17 and Continue 2.0.0.
--
-- `vscode_edition` ships in `extra` because it is the fork, not the extension: the same
-- extension id installed in VS Code, Cursor, Windsurf, VSCodium and Trae is five findings
-- with different blast radii, and only the collector can weigh that.
SELECT 'vscodeext' AS kind, name AS id, version AS ver, path AS loc,
       vscode_edition AS extra, '' AS perms
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN vscode_extensions USING (uid)
