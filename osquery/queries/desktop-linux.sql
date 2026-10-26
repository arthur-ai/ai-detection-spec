-- name: desktop-linux
-- description: Desktop entries, which are the only trace an AppImage or tarball install leaves
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- An AppImage or a tarball leaves no package record, and Cursor's first Linux download is an
-- AppImage. A .desktop filename is the packager's choice: a real identifier, as strong as a
-- cask token and weaker than a bundle id.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no product name appears below (tools/check_no_catalog.py). The
-- glob names where entries land, and the matcher decides what the filenames mean.
--
-- ONE INSTALL CAN WRITE SEVERAL ENTRIES: Cursor's .deb writes cursor.desktop and
-- cursor-url-handler.desktop. So the catalog matches whole filenames: a prefix would count
-- one install twice.
--
-- No version: a desktop entry's `Version=` is the desktop-entry spec's, not the
-- application's, so it would read `1.0` for everything.
SELECT 'desktop' AS kind, filename AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/usr/share/applications/%.desktop'
     OR path LIKE '/usr/local/share/applications/%.desktop'
UNION ALL
-- Per-user entries, where a user-integrated AppImage lands. /root needs its own pattern
-- (CLAUDE.md, Traps).
SELECT 'desktop', filename, '', path, '', '' FROM file
  WHERE path LIKE '/home/%/.local/share/applications/%.desktop'
     OR path LIKE '/root/.local/share/applications/%.desktop'
