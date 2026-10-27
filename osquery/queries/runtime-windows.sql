-- name: runtime-windows
-- description: A marker saying whether Windows has a container engine osquery cannot read
-- tables: users, file, time
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- osquery's docker_* tables are POSIX only (specs/posix at 5.23.1), so on Windows nothing
-- reads a container, and an empty container list would read as a machine with none. This
-- marker says which it is, in the spec's outcome vocabulary (SPEC.md 5.2):
--
--     Docker on disk             -> unreadable:docker
--     Podman on disk             -> unreadable:podman
--     Rancher Desktop on disk    -> unreadable:rancher-desktop
--     none of them               -> absent
--
-- PRESENCE ONLY, never a conversation with the engine, and every engine osquery/bin/
-- container-scan names on POSIX is named here too: an engine this did not look for would read
-- `absent`, the word for a machine with none. Moby's service binary and data root were read
-- off the windows-2025 runner, where the marker reads unreadable:docker, and `absent` with
-- both moved aside (survey run 40396366136). Docker Desktop's, Podman's and Rancher Desktop's
-- directories are their installers' defaults, UNMEASURED: a path that misses reads `absent`.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- The subqueries sit in FROM, not the column list, because test/lint.sh reads a branch's
-- columns as the text between SELECT and the first FROM.
SELECT 'scan' AS kind, 'containers' AS id, CAST(t.unix_time AS TEXT) AS ver,
       '\\.\pipe\docker_engine' AS loc,
       CASE WHEN dm.n + dd.n + dk.n > 0 THEN 'unreadable:docker'
            WHEN pm.n > 0 THEN 'unreadable:podman'
            WHEN rd.n > 0 THEN 'unreadable:rancher-desktop'
            ELSE 'absent' END AS extra,
       '' AS perms
  FROM time t,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\Windows\System32\dockerd.exe') dm,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\ProgramData\docker\') dd,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\Program Files\Docker\Docker\') dk,
       (SELECT COUNT(*) AS n FROM file
         WHERE path = 'C:\Program Files\RedHat\Podman\podman.exe') pm,
       (SELECT COUNT(*) AS n FROM users u
         CROSS JOIN file f ON f.path = u.directory || '\AppData\Local\Programs\Rancher Desktop\'
         WHERE u.directory LIKE '_:\Users\%') rd
