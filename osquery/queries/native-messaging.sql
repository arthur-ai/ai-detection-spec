-- name: native-messaging
-- description: Native messaging bridges between a browser and a desktop app
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- The filename is portable, so the route is posix. The directories are not, so there is a
-- file per platform: this one and queries/native-messaging-linux.sql.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- A single % matches ONE path component, and 'Application Support/Google/Chrome/...' is two,
-- hence the second arm.
-- The stock iCloud Passwords bridge is excluded BY NAME: every Mac ships it in two places,
-- and the 00-baseline control caught it as two phantom findings. A com.apple.% prefix would
-- also swallow a future first-party Apple bridge, which we do want to see.
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
