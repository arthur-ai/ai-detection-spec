-- name: native-messaging
-- description: Native messaging bridges between a browser and a desktop app
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- SPLIT OUT OF browser.sql, which is `posix` now. The VALUE these branches report is a
-- portable filename -- com.anthropic.claude_browser_extension.json is the same string on
-- every OS, which is why the catalog route is `posix`. The DIRECTORIES are not portable
-- in any part, so they are a file per platform: this one, and
-- queries/native-messaging-linux.sql.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- A single % matches ONE path component. 'Application Support/Google/Chrome/...' is TWO,
-- so the one-% form silently missed com.anthropic.claude_browser_extension.json.
-- Excluded by name, not by a 'com.apple.%' prefix. Stock macOS ships this iCloud Passwords
-- bridge in BOTH /Library/Google/Chrome and /Library/.../Mozilla, so every Mac in the fleet
-- reported two phantom native-messaging findings. Caught by the 00-baseline control, which
-- exists for precisely this. A prefix exclusion would be wider than the evidence supports and
-- would swallow any future first-party Apple Intelligence bridge, which we do want to see.
SELECT 'nmh' AS kind, filename AS id, '' AS ver, path AS loc,
       '' AS extra, '' AS perms
  FROM file
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
