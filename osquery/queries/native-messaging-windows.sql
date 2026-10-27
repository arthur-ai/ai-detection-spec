-- name: native-messaging-windows
-- description: Native messaging bridges between a browser and a desktop app, on Windows
-- tables: registry, file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- ON WINDOWS A BRIDGE IS REGISTERED, NOT DISCOVERED BY DIRECTORY: a browser reads the
-- `NativeMessagingHosts\<host>` key's default value, a path to the manifest, under HKCU or
-- HKLM. So this joins the key to the file it names and emits the manifest's FILENAME, the
-- route's portable value. Read off Claude Desktop's own registration: the manifest is
-- com.anthropic.claude_browser_extension.json, the value native-messaging.sql reads on macOS.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no bridge name appears below (tools/check_no_catalog.py). The
-- vendor paths are browsers, at one and two levels below Software (Mozilla, Google\Chrome).
--
-- HKEY_USERS HOLDS LOADED HIVES ONLY: a user who is not signed in has none of their own
-- registrations read (docs/blind-spots.yaml).
SELECT 'nmh' AS kind, f.filename AS id, '' AS ver, f.path AS loc, '' AS extra, '' AS perms
  FROM registry r CROSS JOIN file f ON f.path = r.data
 WHERE r.key LIKE 'HKEY_USERS\%\Software\%\NativeMessagingHosts\%' AND r.name = '(Default)'
UNION ALL
SELECT 'nmh', f.filename, '', f.path, '', ''
  FROM registry r CROSS JOIN file f ON f.path = r.data
 WHERE r.key LIKE 'HKEY_USERS\%\Software\%\%\NativeMessagingHosts\%' AND r.name = '(Default)'
UNION ALL
SELECT 'nmh', f.filename, '', f.path, '', ''
  FROM registry r CROSS JOIN file f ON f.path = r.data
 WHERE r.key LIKE 'HKEY_LOCAL_MACHINE\SOFTWARE\%\NativeMessagingHosts\%' AND r.name = '(Default)'
UNION ALL
SELECT 'nmh', f.filename, '', f.path, '', ''
  FROM registry r CROSS JOIN file f ON f.path = r.data
 WHERE r.key LIKE 'HKEY_LOCAL_MACHINE\SOFTWARE\%\%\NativeMessagingHosts\%' AND r.name = '(Default)'
UNION ALL
SELECT 'nmh', f.filename, '', f.path, '', ''
  FROM registry r CROSS JOIN file f ON f.path = r.data
 WHERE r.key LIKE 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\%\%\NativeMessagingHosts\%'
   AND r.name = '(Default)'
