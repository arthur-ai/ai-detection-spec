-- name: packages-linux
-- description: Every installed deb and rpm package
-- tables: deb_packages, rpm_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: linux
--
-- ONE FILE FOR BOTH FAMILIES, measured: both tables are registered everywhere and return no
-- rows off their own family, exit 0 (osquery 5.23.1, Ubuntu 24.04 and Fedora 41). A table
-- that does not exist at all, such as snap_packages, would fail the whole artifact.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- ENUMERATE, DO NOT MATCH: no package name appears below (tools/check_no_catalog.py).
--
-- THE STATUS PREDICATE IS NOT OPTIONAL. dpkg keeps a removed-but-not-purged package as
-- `deinstall ok config-files`, version attached, so without it an uninstalled agent reads
-- as installed. `%ok installed` keeps `hold ok installed`, which is installed. Testing it
-- needs a package with conffiles: one without vanishes on remove and a broken query passes
-- (74-linux-dpkg-removed).
--
-- `arch` ships in `extra`, so a reader can tell an amd64 install from an arm64 one.
SELECT 'deb' AS kind, name AS id, version AS ver, '' AS loc, arch AS extra, '' AS perms
  FROM deb_packages
  WHERE status LIKE '%ok installed'
UNION ALL
-- rpm's database holds installed packages only, so it needs no status filter. `vendor`
-- ships in `extra`: the one route whose artifact names its own publisher.
SELECT 'rpm', name, version, '', vendor, '' FROM rpm_packages
