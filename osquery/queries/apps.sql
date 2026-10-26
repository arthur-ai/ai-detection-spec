-- name: apps
-- description: Every installed .app bundle
-- tables: apps
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no bundle id appears below. tools/check_no_catalog.py holds that
-- and says why. The cost of enumerating is measured in queries/COST.md.
SELECT 'app' AS kind, bundle_identifier AS id, bundle_short_version AS ver, path AS loc,
       '' AS extra, '' AS perms
  FROM apps
