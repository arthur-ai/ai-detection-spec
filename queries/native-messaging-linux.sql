-- name: native-messaging-linux
-- description: Native messaging bridges between a browser and a desktop app, on Linux
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- THE PATHS ARE READ OFF A REAL CHROME INSTALL, not off Chrome's documentation, and two
-- of them would have been wrong from a reasonable guess:
--
--   * THE CASING DIFFERS BETWEEN SCOPES. The per-user directory is `NativeMessagingHosts`
--     and the system-wide one is `native-messaging-hosts`. osquery's LIKE is
--     case-sensitive, so one pattern cannot serve both and a single spelling would
--     silently return half the answer.
--   * THE USER DIRECTORY SITS AT THE USER-DATA-DIR LEVEL, beside Default/ rather than
--     inside it. A real `google-chrome --user-data-dir=~/.config/google-chrome` run
--     created ~/.config/google-chrome/NativeMessagingHosts/ and no such directory under
--     Default/.
--
-- Chrome did NOT create /etc/opt/chrome on that install -- the system scope is for
-- administrator-placed manifests -- so that branch is looking for something a fleet
-- deploys rather than something the browser makes. That is the branch an MDM-pushed
-- bridge would land in, which is the reason to keep it.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No bridge name appears below.
--
-- One % per path component, and the browser directory is exactly one component --
-- google-chrome, chromium, opera. Unlike macOS there is no 'Application Support' level
-- to step over, so there is no two-% variant to get wrong here.
--
-- No exclusion. The stock macOS iCloud Passwords bridge has no Linux equivalent: nothing
-- in a Linux base install ships a native-messaging manifest, verified on a clean Ubuntu
-- 24.04 container where all three branches returned nothing until one was planted.
SELECT 'nmh' AS kind, filename AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/home/%/.config/%/NativeMessagingHosts/%.json'
     OR path LIKE '/root/.config/%/NativeMessagingHosts/%.json'
UNION ALL
-- Firefox uses a lower-case directory in the user scope as well, and it is not under
-- .config at all.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.mozilla/native-messaging-hosts/%.json'
     OR path LIKE '/root/.mozilla/native-messaging-hosts/%.json'
UNION ALL
-- The system scope: /etc/opt/chrome/... for Chrome, /etc/chromium/... for Chromium, and
-- /usr/lib/mozilla/... for Firefox. Two patterns because the depth differs by one.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/etc/%/native-messaging-hosts/%.json'
     OR path LIKE '/etc/opt/%/native-messaging-hosts/%.json'
     OR path LIKE '/usr/lib/%/native-messaging-hosts/%.json'
