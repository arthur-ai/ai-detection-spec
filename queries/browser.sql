-- name: browser
-- description: Browser extensions with their permissions
-- tables: users, file, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- POSIX, AND THE NATIVE-MESSAGING BRANCHES MOVED OUT to queries/native-messaging.sql and
-- queries/native-messaging-linux.sql. chrome_extensions is cross-platform and needs no
-- per-OS knowledge at all -- osquery carries the profile directories itself, and its
-- Linux list (osquery/tables/applications/chrome/utils.cpp) covers .config/google-chrome,
-- .config/chromium, Brave, Opera, Vivaldi, Yandex AND snap/chromium/common/chromium. The
-- native-messaging branches are the opposite: nothing but hardcoded per-OS paths.
--
-- VERIFIED ON A REAL LINUX PROFILE, because three hand-built ones returned nothing:
-- osquery validates a profile by reading its Preferences file, and a fixture that merely
-- looks right does not pass. A real `google-chrome --headless=new --user-data-dir` profile
-- returned a row at once, with browser_type 'chrome' and the same permissions format
-- macOS gives. That is why 75-linux-browser installs a real browser rather than planting
-- a directory tree.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- CROSS JOIN is mandatory. A plain JOIN ... USING (uid) returns ZERO rows silently:
-- osquery needs the uid constraint pushed into user-scoped tables.
--
-- THE UID LIST COMES FROM DISK AS WELL AS FROM `users`, because on Linux `users` is not
-- the list of users. Since osquery 5.13.1 (osquery/osquery#8342) the unconstrained Linux
-- table reads /etc/passwd directly, so that an LDAP site does not pay a directory query
-- per scan -- and every account an NSS module supplies is absent from it: GCE OS Login,
-- SSSD, LDAP, Active Directory through realmd. Joined to that list, this branch skipped
-- exactly the users a server has and returned the shape a clean machine does. Read off
-- osquery/tables/system/linux/users.cpp at 5.23.1, and test/run-gce.sh is what shows it
-- on an OS Login VM.
--
-- Constrained by ONE uid the table does fall through to NSS (usersFromContext retries
-- with include_remote=1), so the fix is to supply the uids rather than ask for them: the
-- owner of every home directory on disk. That is the set of accounts that have logged in,
-- which is the set that can own a browser profile. UNION rather than replacement keeps a
-- user whose home is elsewhere. An NSS-only account with a home outside /home, /root and
-- /Users is the gap left, and docs/blind-spots.yaml carries it. Both platforms' roots are
-- globbed because this file is posix: /home on macOS is an empty autofs map (0 rows,
-- 0.37s for the whole statement) and /Users does not exist on Linux. Measured 2026-10-04
-- on a reference Mac: 81 ext rows from either list, so nothing moves where `users` was
-- already complete.
--
-- `permissions`, NOT `permissions_json`. Verified against osquery 5.23.1 in 40-browser:
-- permissions_json serialises a JSON ARRAY as an object with repeated empty keys --
--   {"":"tabs","":"cookies","":"nativeMessaging"}
-- which is not round-trippable and would silently collapse to one key in any strict
-- parser. The flat `permissions` column is comma-separated and correct.
--
-- manifest_json deliberately does not ship. It is the one column that would blow the
-- 30KB EA budget: a developer Mac carries ~95 extensions with multi-KB manifests each.
--
-- '<all_urls>' is the "reads every authenticated page" signal, and under MV3 it lives in
-- host_permissions - a manifest key osquery models in NO column except manifest_json.
-- Shipping manifest_json to recover it is not affordable. Measured on a reference Mac
-- with 98 extension rows:
--
--     permissions only ............  2.26 KB EA payload
--     + manifest_json .............  86.57 KB   - 2.9x OVER the 30KB budget
--     + all_urls flag below .......  2.29 KB   - 38x cheaper, same signal
--
-- So the flag is computed HERE, in SQL, and only its result travels. 30 bytes for the
-- whole fleet-visible signal. The provenance tokens below were measured the same way on
-- 2026-10-07, on a Mac with 90 rows, 46 of them unreferenced: 2.21 KB before, 2.30 after.
--
-- This is a substring match over the raw manifest, so it is deliberately imprecise: it
-- cannot distinguish host_permissions from optional_host_permissions, and an extension
-- merely mentioning the string in a description would match. That is the correct bias
-- under D17 - the endpoint over-selects, the collector classifies. A false positive
-- costs one triage row, a false negative hides an extension reading every page.
-- PROVENANCE, appended after the flag above so every existing substring still holds. One
-- CASE, so the two tokens cannot both appear:
--
--   unreferenced         on disk and absent from the profile's Preferences, so Chrome
--                        will not load it: a leftover, or a directory planted by hand
--   sideloaded:<sha256>  registered, and not from the Web Store. The hash is osquery's
--                        manifest_hash, carried only here because only here does it
--                        identify something the id cannot: a sideloaded build has no key
--
-- `!= 'true'` and not `= 'false'`: osquery passes the stored string through, so a store
-- install reads 'true', an unpacked one 'false', and a missing setting ''. A store row
-- carries neither token. `from_webstore` must stay lowercase: lint splits the column
-- list on the first upper-case FROM.
--
-- ALIASED, and every branch's first arm must be. A UNION ALL takes its column NAMES from
-- the first arm only, so an unaliased first arm inherits whatever precedes it -- which is
-- whatever sorts before it in a composed artifact, and NOTHING standalone. Run
-- standalone unaliased, osquery named the columns 'ext', identifier, browser_type and
-- "permissions || CASE WHEN manifest_json LIKE ...", and dist/ai-discovery.conf shipped
-- that: the pack's browser query returned 74 rows that no consumer of the six-column
-- contract could read. tools/check_pack.py counted the rows and passed it, and test/lint.sh
-- checked the column COUNT and passed it. Both now check the names.
SELECT 'ext' AS kind, identifier AS id, version AS ver, profile_path AS loc,
       browser_type AS extra,
       permissions
         || CASE WHEN manifest_json LIKE '%<all_urls>%' THEN ',<all_urls>' ELSE '' END
         || CASE WHEN referenced = 0 THEN ',unreferenced'
                 WHEN from_webstore != 'true'
                   THEN ',sideloaded:' || IFNULL(manifest_hash, '')
                 ELSE '' END
         AS perms
  FROM (SELECT uid FROM users
        UNION
        SELECT uid FROM file
         WHERE path LIKE '/home/%/' OR path = '/root/' OR path LIKE '/Users/%/') u
       CROSS JOIN chrome_extensions USING (uid)
