-- name: browser
-- description: Browser extensions with their permissions
-- tables: users, file, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- chrome_extensions carries every Chromium browser's profile directories itself, on both
-- platforms (osquery's tables/applications/chrome/utils.cpp). It validates a profile by its
-- Preferences file, so a hand-built fixture returns nothing, and 75-linux-browser installs a
-- real browser for that reason.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- CROSS JOIN, because a plain JOIN on a user-scoped table returns zero rows (CLAUDE.md,
-- Traps). This file is the home of the uid list that vscode, jetbrains and packages reuse.
--
-- THE UIDS COME FROM DISK AS WELL AS FROM `users`. Since osquery 5.13.1 (osquery/osquery#8342)
-- an unconstrained Linux `users` reads /etc/passwd only, so an account an NSS module
-- supplies -- GCE OS Login, SSSD, LDAP, AD through realmd -- is absent, and this branch
-- returned a clean machine's shape for exactly the users a server has (test/run-gce.sh shows
-- it). A lookup by uid does reach NSS, so the owners of the home directories on disk are
-- supplied. Gap left: an NSS-only account with its home outside /home, /root and /Users
-- (docs/blind-spots.yaml).
--
-- `permissions`, NOT `permissions_json`, which serialises an array as an object with
-- repeated empty keys -- {"":"tabs","":"cookies"} -- that a strict parser collapses.
--
-- manifest_json DOES NOT SHIP: on a 98-extension Mac it took the payload from 2.3 KB to
-- 87 KB, past the 30KB EA budget (a convention, in the root CLAUDE.md). Under MV3
-- '<all_urls>' lives in host_permissions, which only manifest_json carries, so the flag is
-- computed here and only its result ships. It is a substring match and over-selects (a
-- description mentioning the string matches), which is the right bias: a false positive
-- costs a triage row, a false negative hides an extension reading every page.
--
-- `extra` IS THE BROWSER, then at most one provenance token. Provenance is not a capability,
-- so it stays out of `perms`, which holds permissions and the flag only (SPEC.md 5.1):
--
--   unreferenced         on disk and absent from the profile's Preferences, so Chrome
--                        will not load it: a leftover, or a directory planted by hand
--   sideloaded:<sha256>  registered, and not from the Web Store. The hash is osquery's
--                        manifest_hash, because a sideloaded build need not carry a key,
--                        and without one its id is empty
--
-- `!= 'true'`, not `= 'false'`: a store install reads 'true', an unpacked one 'false', a
-- missing setting ''. `from_webstore` stays lowercase because lint splits the column list
-- on the first upper-case FROM. Aliased, as every first arm must be (CLAUDE.md, Traps).
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
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN chrome_extensions USING (uid)
