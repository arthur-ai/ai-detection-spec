-- name: browser
-- description: Browser extensions with their permissions, and native messaging bridges
-- tables: users, chrome_extensions, file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- CROSS JOIN is mandatory. A plain JOIN ... USING (uid) returns ZERO rows silently:
-- osquery needs the uid constraint pushed into user-scoped tables.
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
-- whole fleet-visible signal.
--
-- This is a substring match over the raw manifest, so it is deliberately imprecise: it
-- cannot distinguish host_permissions from optional_host_permissions, and an extension
-- merely mentioning the string in a description would match. That is the correct bias
-- under D17 - the endpoint over-selects, the collector classifies. A false positive
-- costs one triage row, a false negative hides an extension reading every page.
-- ALIASED, and every branch's first arm must be. A UNION ALL takes its column NAMES from
-- the first arm only, so an unaliased first arm inherits whatever precedes it -- which is
-- apps.sql inside dist/discovery.sql, and NOTHING when this file runs on its own. Run
-- standalone unaliased, osquery named the columns 'ext', identifier, browser_type and
-- "permissions || CASE WHEN manifest_json LIKE ...", and dist/ai-discovery.conf shipped
-- that: the pack's browser query returned 74 rows that no consumer of the six-column
-- contract could read. tools/check_pack.py counted the rows and passed it, and test/lint.sh
-- checked the column COUNT and passed it. Both now check the names.
SELECT 'ext' AS kind, identifier AS id, version AS ver, profile_path AS loc,
       browser_type AS extra,
       permissions || CASE WHEN manifest_json LIKE '%<all_urls>%' THEN ',<all_urls>' ELSE '' END
         AS perms
  FROM users CROSS JOIN chrome_extensions USING (uid)
UNION ALL
-- A single % matches ONE path component. 'Application Support/Google/Chrome/...' is TWO,
-- so the one-% form silently missed com.anthropic.claude_browser_extension.json.
-- Excluded by name, not by a 'com.apple.%' prefix. Stock macOS ships this iCloud Passwords
-- bridge in BOTH /Library/Google/Chrome and /Library/.../Mozilla, so every Mac in the fleet
-- reported two phantom native-messaging findings. Caught by the 00-baseline control, which
-- exists for precisely this. A prefix exclusion would be wider than the evidence supports and
-- would swallow any future first-party Apple Intelligence bridge, which we do want to see.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/Library/Application Support/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'
UNION ALL
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/Library/Application Support/%/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'
UNION ALL
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Library/%/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'
