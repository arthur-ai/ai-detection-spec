-- name: apps
-- description: Installed .app bundles for known AI desktop applications
-- tables: apps
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- Arthur endpoint discovery — coarse selection predicate (D17).
-- SINGLE SOURCE OF TRUTH: the Jamf EA script and the test harness both consume this file.
--
-- Every construct below encodes a defect found on real hardware during UP-4881/UP-4882.
-- Read the comments before "simplifying" anything here.

SELECT 'app' AS kind, bundle_identifier AS id, bundle_short_version AS ver, path AS loc,
       '' AS extra, '' AS perms
  FROM apps
  WHERE bundle_identifier IN (
    'com.anthropic.claudefordesktop','com.openai.codex','com.todesktop.230313mzl4w4u92',
    'com.electron.ollama','ai.perplexity.comet','ai.perplexity.macv3',
    -- OpenClaw ships 'ai.openclaw.mac'. Read off a real 2026.7.1 install in a VM, because
    -- the design's 'bot.molt.mac' was WRONG and would have missed the demo's punchline on
    -- every Mac. The Homebrew cask's zap stanza still lists bot.molt.mac paths, which is
    -- what misled us -- zap enumerates artifacts to clean up INCLUDING historical ones, so
    -- it is a superset of current identity and must never be read as the bundle id.
    -- The old id stays as an alias (R9): machines that installed Moltbot still carry it.
    'ai.openclaw.mac','bot.molt.mac',
    'com.exafunction.windsurf','ai.elementlabs.lmstudio','jan.ai.app','com.kagi.kagimacOS',
    -- Docker Desktop itself. Not an AI tool, but the `image` branch below returns ZERO rows
    -- whenever its daemon is stopped -- indistinguishable from "no AI containers". Knowing
    -- Docker is INSTALLED lets the collector tell "nothing there" from "we could not look".
    'com.docker.docker')
