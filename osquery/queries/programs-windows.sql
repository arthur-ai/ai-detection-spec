-- name: programs-windows
-- description: Every MSIX package by its family name, the Windows identity a Store or sideloaded app keeps across versions
-- tables: programs
-- min-osquery: 5.17.0
-- cost: slow
-- platform: windows
--
-- min-osquery IS 5.17.0, where `programs` learned MSIX packages (osquery/osquery#8585).
-- Older, the column is absent and this query exits 1, so it is its own pack entry and
-- composed branch, as vscode.sql is.
--
-- SLOW, MEASURED: 7.2s on a cold windows-2025 runner and 0.4s warm (survey run 40396366136).
-- The table reads every package's AppxManifest.xml off disk.
--
-- HKEY_USERS HOLDS LOADED HIVES ONLY: a package installed for a user who is not signed in
-- is not here, unless it is provisioned for every user (docs/blind-spots.yaml).
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- `package_family_name` is `<Name>_<PublisherHash>`: the version and architecture are not in
-- it, so it is the bundle id's counterpart. A Win32 install's row carries none and is read by
-- uninstall-windows.sql instead, whose key names the install where this table does not.
-- `extra` is the publisher's display name.
SELECT 'msix' AS kind, package_family_name AS id, version AS ver, install_location AS loc,
       publisher AS extra, '' AS perms
  FROM programs
 WHERE package_family_name != ''
