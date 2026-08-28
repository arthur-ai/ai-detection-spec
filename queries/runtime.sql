-- name: runtime
-- description: Unattended agents and local inference servers that are running now
-- tables: launchd, listening_ports, processes
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

SELECT 'daemon', label, '', path, '', '' FROM launchd
  WHERE label LIKE 'ai.openclaw%' OR label LIKE 'com.ollama%' OR label LIKE 'bot.molt%'
UNION ALL
SELECT 'port', CAST(lp.port AS TEXT), '', p.path, p.name, ''
  FROM listening_ports lp JOIN processes p USING (pid)
  WHERE lp.port IN (11434,1234,18789,8080)
