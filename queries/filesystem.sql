-- name: filesystem
-- description: CLI agent binaries, agent state directories and local model stores
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

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
-- Namespace-safe: hardcoding registry.ollama.ai/library misses org-hosted or hf.co models.
SELECT 'model', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.ollama/models/manifests/%/%/%/%'
