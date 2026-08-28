-- name: packages
-- description: AI tooling installed through npm, Homebrew, pipx or uv
-- tables: npm_packages, homebrew_packages
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

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
