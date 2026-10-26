-- name: ports
-- description: Every process holding a listening port
-- tables: listening_ports, processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: posix
--
-- RAW EVIDENCE, NOT A SIGNATURE. The `ports` route is retired (catalog/agents.yaml's header
-- says why), so these rows produce no findings. They still ship, because an unrecognised
-- process listening unattended is worth a reader's time, and the kind stays registered in
-- catalog/routes.yaml so they arrive unmatched rather than dropped.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- `port > 0` is structural: port 0 rows are unix sockets and non-listening entries. The bind
-- address ships in `extra`, because 0.0.0.0 is a sharper finding than loopback and only the
-- reader can weigh that. Aliased, as every first arm must be (CLAUDE.md, Traps).
SELECT 'port' AS kind, CAST(lp.port AS TEXT) AS id, '' AS ver, p.path AS loc,
       lp.address AS extra, '' AS perms
  FROM listening_ports lp JOIN processes p USING (pid)
  WHERE lp.port > 0
