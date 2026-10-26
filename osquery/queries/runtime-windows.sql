-- name: runtime-windows
-- description: A marker saying whether Windows has a container engine osquery cannot read
-- tables: file, time
-- min-osquery: 5.10.0
-- cost: fast
-- platform: windows
--
-- osquery's docker_* tables are POSIX only (specs/posix at 5.23.1), so on Windows nothing
-- reads a container, and an empty container list would read as a machine with none. This
-- marker says which it is, in the spec's outcome vocabulary (SPEC.md 5.2):
--
--     an engine on disk   -> unreadable:docker   present, and not read
--     none                -> absent
--
-- PRESENCE ONLY, never a conversation with the engine: the POSIX side names Podman the same
-- way (osquery/bin/container-scan). Moby's service binary and data root were read off the
-- windows-2025 runner, where the marker reads unreadable:docker, and `absent` with both moved
-- aside (survey run 40396366136). Docker Desktop's directory is its documented default,
-- unmeasured.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- The subqueries sit in FROM, not the column list, because test/lint.sh reads a branch's
-- columns as the text between SELECT and the first FROM.
SELECT 'scan' AS kind, 'containers' AS id, CAST(t.unix_time AS TEXT) AS ver,
       '\\.\pipe\docker_engine' AS loc,
       CASE WHEN m.n + d.n + dd.n > 0 THEN 'unreadable:docker' ELSE 'absent' END AS extra,
       '' AS perms
  FROM time t,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\Windows\System32\dockerd.exe') m,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\ProgramData\docker\') d,
       (SELECT COUNT(*) AS n FROM file WHERE path = 'C:\Program Files\Docker\Docker\') dd
