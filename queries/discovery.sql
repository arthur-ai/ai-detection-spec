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

UNION ALL
-- npm_packages recurses into each global's own node_modules: 883 rows -> 7 without this predicate.
SELECT 'npm', name, version, path, '', '' FROM npm_packages
  WHERE path NOT LIKE '%/node_modules/%/node_modules/%'
    AND (name LIKE '@anthropic-ai/%' OR name LIKE '@openai/%' OR name LIKE '@modelcontextprotocol/%'
         -- Scoped by vendor, so the @anthropic-ai/@openai globs above miss them. Named
         -- explicitly rather than globbing @google/% or @github/%, which are mostly not AI.
         OR name IN ('openclaw','moltbot','clawdbot','aider','cline','litellm','ollama','mcp',
                     '@google/gemini-cli','@github/copilot'))

UNION ALL
-- homebrew_packages covers BOTH formulae and casks -- it has a `type` column returning
-- 'formula' or 'cask', and cask rows carry a /opt/homebrew/Caskroom/... path. An earlier
-- reading of this was wrong: a scenario installing an ollama formula AND an ollama-app
-- cask returned one row, and we concluded casks were unmodelled rather than checking.
SELECT 'brew', name, version, path, type, '' FROM homebrew_packages
  WHERE name IN ('ollama','ollama-app','aider','codex','gemini-cli','copilot-cli',
                 'llama.cpp','openclaw','lm-studio','jan','claude','cursor')

UNION ALL
SELECT 'daemon', label, '', path, '', '' FROM launchd
  WHERE label LIKE 'ai.openclaw%' OR label LIKE 'com.ollama%' OR label LIKE 'bot.molt%'

UNION ALL
SELECT 'port', CAST(lp.port AS TEXT), '', p.path, p.name, ''
  FROM listening_ports lp JOIN processes p USING (pid)
  WHERE lp.port IN (11434,1234,18789,8080)

UNION ALL
-- CROSS JOIN is mandatory. A plain JOIN ... USING (uid) returns ZERO rows silently:
-- osquery needs the uid constraint pushed into user-scoped tables.
--
-- `permissions`, NOT `permissions_json`. Verified against osquery 5.23.1 in 40-browser:
-- permissions_json serialises a JSON ARRAY as an object with repeated empty keys --
--   {"":"tabs","":"cookies","":"nativeMessaging"}
-- which is not round-trippable and would silently collapse to one key in any strict
-- parser. The flat `permissions` column is comma-separated and correct.
--
-- manifest_json deliberately does not ship. It is the one column that would blow the
-- 30KB EA budget: a developer Mac carries ~95 extensions with multi-KB manifests each.
--
-- '<all_urls>' is the "reads every authenticated page" signal, and under MV3 it lives in
-- host_permissions - a manifest key osquery models in NO column except manifest_json.
-- Shipping manifest_json to recover it is not affordable. Measured on a reference Mac
-- with 98 extension rows:
--
--     permissions only ............  2.26 KB EA payload
--     + manifest_json .............  86.57 KB   - 2.9x OVER the 30KB budget
--     + all_urls flag below .......  2.29 KB   - 38x cheaper, same signal
--
-- So the flag is computed HERE, in SQL, and only its result travels. 30 bytes for the
-- whole fleet-visible signal.
--
-- This is a substring match over the raw manifest, so it is deliberately imprecise: it
-- cannot distinguish host_permissions from optional_host_permissions, and an extension
-- merely mentioning the string in a description would match. That is the correct bias
-- under D17 - the endpoint over-selects, the collector classifies. A false positive
-- costs one triage row, a false negative hides an extension reading every page.
SELECT 'ext', identifier, version, profile_path, browser_type,
       permissions || CASE WHEN manifest_json LIKE '%<all_urls>%' THEN ',<all_urls>' ELSE '' END
  FROM users CROSS JOIN chrome_extensions USING (uid)

UNION ALL
SELECT 'file', path, '', path, '', '' FROM file WHERE path LIKE '/Users/%/.local/bin/claude'

UNION ALL
-- Agent STATE DIRECTORIES. The most install-method-independent signal available: a cask,
-- an npm global, `curl install.sh | bash` and a source checkout all converge on the same
-- dotdir the first time the agent runs. Package-manager branches see only the route that
-- was used, and see nothing at all for a source build or a pnpm workspace.
--
-- THE TRAILING SLASH IS LOAD-BEARING. osquery translates LIKE into its glob engine, where
-- a directory must be addressed with a trailing slash:
--     path LIKE '/Users/%/.claude'   -> 0 rows, no error
--     path LIKE '/Users/%/.claude/'  -> the directory
-- Same silent-zero shape as the JOIN and the one-% glob. Do not "tidy" the slash away.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.openclaw/'
     OR path LIKE '/Users/%/.claude/'
     OR path LIKE '/Users/%/.codex/'
     OR path LIKE '/Users/%/.aider/'
     -- npx/bunx leave the package in a content-addressed cache rather than a global root,
     -- so npm_packages never sees it. Bounded glob, one component per %.
     OR path LIKE '/Users/%/.npm/_npx/%/node_modules/openclaw/'
     OR path LIKE '/Users/%/.npm/_npx/%/node_modules/@anthropic-ai/'

UNION ALL
-- PYTHON-PACKAGED AGENTS. python_packages is deliberately absent from this query (15.6s,
-- no WHERE push-down -- see the note at the end), which leaves pipx, uv and pip --user
-- installs invisible. That is not a small corner: aider, litellm, crewai, langgraph,
-- open-interpreter and most MCP servers ship on PyPI first and some ONLY there.
--
-- The design justified dropping python_packages as contributing "zero Tier A matches",
-- but that was measured on a machine with none of them installed -- absence of evidence
-- read as evidence of absence. Verified on PyPI: aider-chat, litellm, crewai, langgraph,
-- mcp and open-interpreter all publish there today.
--
-- So glob the INSTALL LOCATIONS instead of querying the slow table. Both managers give
-- each tool its own directory named for the package, which is precise, bounded and free.
-- Trailing slash for the same reason as above.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.local/pipx/venvs/%/'
     OR path LIKE '/Users/%/.local/share/uv/tools/%/'

UNION ALL
-- A single % matches ONE path component. 'Application Support/Google/Chrome/...' is TWO,
-- so the one-% form silently missed com.anthropic.claude_browser_extension.json.
-- Excluded by name, not by a 'com.apple.%' prefix. Stock macOS ships this iCloud Passwords
-- bridge in BOTH /Library/Google/Chrome and /Library/.../Mozilla, so every Mac in the fleet
-- reported two phantom native-messaging findings. Caught by the 00-baseline control, which
-- exists for precisely this. A prefix exclusion would be wider than the evidence supports and
-- would swallow any future first-party Apple Intelligence bridge, which we do want to see.
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/Library/Application Support/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'
UNION ALL
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/Library/Application Support/%/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'
UNION ALL
SELECT 'nmh', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Library/%/%/NativeMessagingHosts/%.json'
    AND filename != 'com.apple.passwordmanager.json'

UNION ALL
-- Namespace-safe: hardcoding registry.ollama.ai/library misses org-hosted or hf.co models.
SELECT 'model', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.ollama/models/manifests/%/%/%/%';

-- DELIBERATELY ABSENT: docker_images.
-- Measured on a reference Mac, and the worst case is the COMMON case:
--
--     daemon running .................. fast, returns rows
--     no socket file at all ...........  0.35s, fails fast
--     socket present, daemon STOPPED .. 10.37s   <-- Docker Desktop installed, not running
--
-- osquery blocks on a connect timeout. That one branch took the whole query from under a
-- second to 11.2s -- past the 10s Extension Attribute budget -- while returning ZERO rows.
-- Most developer Macs are in that third state most of the time.
--
-- It measured 1-2s in the VM suite because that VM had no Docker installed at all, which is
-- exactly the state that hides it. Containers move to the pack format, where a scheduled
-- runner can afford the stall. Do not reinstate this branch inline without re-measuring
-- against a stopped daemon.
--
-- DELIBERATELY ABSENT: python_packages.
-- 15.6s per scan, does not honour WHERE push-down, and contributed zero Tier A matches.
-- It took the full query from 2.0s to 78s. When Tier B detection lands it goes in a
-- Jamf policy writing a cache file, never inline in an Extension Attribute.
