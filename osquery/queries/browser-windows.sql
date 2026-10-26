-- name: browser-windows
-- description: Browser extensions with their permissions, on Windows
-- tables: users, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- The Windows twin of browser.sql, whose comments explain the columns, the provenance tokens
-- in `extra` and the `<all_urls>` flag in `perms`.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- THE UIDS COME FROM `users` ALONE. On Windows it reads the ProfileList, so every account
-- with a profile is in it, and the home-directory fallback browser.sql needs for NSS-only
-- Linux accounts has nothing to add. CROSS JOIN for the reason browser.sql gives.
SELECT 'ext' AS kind, identifier AS id, version AS ver, profile_path AS loc,
       browser_type
         || CASE WHEN referenced = 0 THEN ',unreferenced'
                 WHEN from_webstore != 'true'
                   THEN ',sideloaded:' || IFNULL(manifest_hash, '')
                 ELSE '' END
         AS extra,
       permissions
         || CASE WHEN manifest_json LIKE '%<all_urls>%' THEN ',<all_urls>' ELSE '' END
         AS perms
  FROM (SELECT uid FROM users) u
       CROSS JOIN chrome_extensions USING (uid)
