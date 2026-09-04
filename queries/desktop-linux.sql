-- name: desktop-linux
-- description: Desktop entries, which are the only trace an AppImage or tarball install leaves
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- THE NEAREST THING LINUX HAS TO apps.sql, and it exists for one reason the package
-- routes cannot cover: AN AppImage OR A TARBALL LEAVES NO PACKAGE RECORD AT ALL. Cursor's
-- primary Linux download is an AppImage -- cursor.com/api/download offers it first, with
-- the .deb and .rpm as alternatives -- so without this branch the most common way that
-- agent arrives on Linux is invisible on every other route.
--
-- A .desktop filename is chosen by whoever packaged the software, which is the same trust
-- level as a Homebrew cask token and weaker than a bundle id. It is a real identifier
-- and it is not a strong one. The catalog comment beside each value says which install
-- produced it.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No product name appears below -- the glob names the
-- LOCATIONS a desktop entry lands in, and the collector decides what the filenames mean.
--
-- ONE INSTALL CAN WRITE SEVERAL ENTRIES, which is why the catalog matches one filename
-- rather than a prefix. Read off real installs: Cursor's .deb writes cursor.desktop AND
-- cursor-url-handler.desktop, and google-chrome-stable writes both
-- com.google.Chrome.desktop and google-chrome.desktop. So filenames come in a reverse-DNS
-- and a bare shape, and a prefix match would count one install as two findings.
--
-- No version. A desktop entry carries `Version=` for the DESKTOP ENTRY SPEC it conforms
-- to, not for the application, so reading it would report `1.0` for everything. `ver` is
-- empty rather than wrong, and routes.yaml records that this route carries none.
SELECT 'desktop' AS kind, filename AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/usr/share/applications/%.desktop'
     OR path LIKE '/usr/local/share/applications/%.desktop'
UNION ALL
-- Per-user entries, which is where an AppImage integrated by the user lands rather than
-- anywhere system-wide. /root again gets its own pattern -- see filesystem-linux.sql.
SELECT 'desktop', filename, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.local/share/applications/%.desktop'
     OR path LIKE '/root/.local/share/applications/%.desktop'
