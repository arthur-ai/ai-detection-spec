-- name: uninstall-windows
-- description: Every installed program by its Uninstall key, machine-wide and for each signed-in user
-- tables: registry
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- `id` IS THE KEY'S NAME, which the installer chooses and keeps across versions: Inno Setup
-- writes `<AppId>_is1`, Squirrel the app name. `programs` reads the same keys and does not
-- expose the name, and its `identifying_number` is an MSI ProductCode, which changes with every
-- major upgrade. `extra` is the DisplayName, `ver` the DisplayVersion, `loc` the key.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no key name appears below (tools/check_no_catalog.py).
--
-- HKEY_USERS HOLDS LOADED HIVES ONLY: a per-user install by someone not signed in is not
-- here, though its files are (docs/blind-spots.yaml).
SELECT 'uninstall' AS kind, regex_match(n.key, '[^\\]+$', 0) AS id, IFNULL(v.data, '') AS ver,
       n.key AS loc, n.data AS extra, '' AS perms
  FROM registry n
       LEFT JOIN registry v ON v.key = n.key AND v.name = 'DisplayVersion'
 WHERE n.key LIKE 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\%'
   AND n.name = 'DisplayName'
UNION ALL
SELECT 'uninstall', regex_match(n.key, '[^\\]+$', 0), IFNULL(v.data, ''), n.key, n.data, ''
  FROM registry n
       LEFT JOIN registry v ON v.key = n.key AND v.name = 'DisplayVersion'
 WHERE n.key LIKE 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\%'
   AND n.name = 'DisplayName'
UNION ALL
SELECT 'uninstall', regex_match(n.key, '[^\\]+$', 0), IFNULL(v.data, ''), n.key, n.data, ''
  FROM registry n
       LEFT JOIN registry v ON v.key = n.key AND v.name = 'DisplayVersion'
 WHERE n.key LIKE 'HKEY_USERS\%\Software\Microsoft\Windows\CurrentVersion\Uninstall\%'
   AND n.name = 'DisplayName'
