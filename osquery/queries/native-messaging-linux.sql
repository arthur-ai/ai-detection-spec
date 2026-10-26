-- name: native-messaging-linux
-- description: Native messaging bridges between a browser and a desktop app, on Linux
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- THE PATHS ARE READ OFF A REAL CHROME INSTALL, and two differ from a reasonable guess:
--
--   * THE CASING DIFFERS BY SCOPE: `NativeMessagingHosts` per user, `native-messaging-hosts`
--     system-wide. LIKE is case-sensitive here, so one spelling returns half the answer.
--   * THE USER DIRECTORY SITS BESIDE Default/, at the user-data-dir level, not inside it.
--
-- Chrome creates nothing under /etc/opt/chrome. That scope holds what an administrator or
-- an MDM places, which is why it is searched.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no bridge name appears below (tools/check_no_catalog.py).
--
-- The browser directory is one path component, so one % per component suffices. No
-- exclusion: a clean Ubuntu 24.04 ships no native-messaging manifest.
SELECT 'nmh' AS kind, filename AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/home/%/.config/%/NativeMessagingHosts/%.json'
     OR path LIKE '/root/.config/%/NativeMessagingHosts/%.json'
UNION ALL
-- Firefox: lower-case in the user scope too, and not under .config.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.mozilla/native-messaging-hosts/%.json'
     OR path LIKE '/root/.mozilla/native-messaging-hosts/%.json'
UNION ALL
-- The system scope: /etc/opt/chrome, /etc/chromium and /usr/lib/mozilla, at two depths.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/etc/%/native-messaging-hosts/%.json'
     OR path LIKE '/etc/opt/%/native-messaging-hosts/%.json'
     OR path LIKE '/usr/lib/%/native-messaging-hosts/%.json'
