-- name: filesystem
-- description: Home-directory install locations: CLI shims, state dotdirs, tool venvs, model stores
-- tables: file
-- min-osquery: 5.10.0
-- cost: fast
-- platform: darwin
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- ENUMERATE, DO NOT MATCH (D20). No agent name appears in any glob below.
--
-- `file` is the one table that cannot simply be selected from: it has no rows until a
-- path pattern constrains it. So enumeration here means globbing the LOCATIONS where a
-- user-installed tool lands, and letting the collector decide what the names mean. The
-- shape of a path is not a catalog. 'Anything directly under ~/.local/bin' names no
-- product, while '~/.local/bin/claude' names one.

-- CLI shims. Was pinned to a single filename, now every entry, so an agent nobody has
-- catalogued yet still arrives.
SELECT 'file' AS kind, path AS id, '' AS ver, path AS loc, '' AS extra, '' AS perms
  FROM file
  WHERE path LIKE '/Users/%/.local/bin/%'
UNION ALL
-- STATE DIRECTORIES, the most install-route-independent signal available: a cask, an npm
-- global, `curl install.sh | bash` and a source checkout all converge on the same dotdir
-- the first time the agent runs. Package-manager branches see only the route that was
-- used, and see nothing at all for a source build.
--
-- THE TRAILING SLASH IS LOAD-BEARING. osquery translates LIKE into its glob engine, where
-- a directory must be addressed with a trailing slash:
--     path LIKE '/Users/%/.claude'   -> 0 rows, no error
--     path LIKE '/Users/%/.claude/'  -> the directory
-- Same silent-zero shape as the JOIN and the one-% glob. Do not "tidy" the slash away.
--
-- Every top-level dotdir now, not four named ones. 47 on a loaded reference Mac, which is
-- affordable, and it means a new agent's state directory is evidence on the first scan
-- rather than after a fleet redeploy.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.%/'
UNION ALL
-- PYTHON-PACKAGED AGENTS. python_packages is deliberately absent from this query (15.6s,
-- no WHERE push-down), which would leave pipx, uv and pip --user installs invisible. That
-- is not a small corner: aider, litellm, crewai, langgraph, open-interpreter and most MCP
-- servers ship on PyPI first and some ONLY there.
--
-- The design justified dropping python_packages as contributing "zero Tier A matches",
-- but that was measured on a machine with none of them installed -- absence of evidence
-- read as evidence of absence.
--
-- So glob the INSTALL LOCATIONS instead of querying the slow table. Both managers give
-- each tool its own directory named for the package, which is precise, bounded and free.
-- These globs were already product-free and are unchanged.
SELECT 'file', path, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.local/pipx/venvs/%/'
     OR path LIKE '/Users/%/.local/share/uv/tools/%/'
UNION ALL
-- LOCAL MODEL STORES. Was '/Users/%/.ollama/models/manifests/...', which named a product
-- and would miss any other runtime adopting the same layout. The dotdir is a % now.
--
-- Verified equivalent rather than assumed: built the exact manifest tree Ollama creates
-- (manifests/<host>/<namespace>/<name>/<tag>) with a library model and an hf.co one, and
-- both globs returned the same 2 rows. The four %s are one per path component, and the
-- fourth is what catches a model outside the 'library' namespace -- hardcoding
-- registry.ollama.ai/library returns 1 of 2 and looks perfectly healthy.
SELECT 'model', filename, '', path, '', '' FROM file
  WHERE path LIKE '/Users/%/.%/models/manifests/%/%/%/%'

-- KNOWN GAP, deliberately not covered: packages executed via `npx`/`bunx` and never
-- installed. They land in a content-addressed cache, /Users/x/.npm/_npx/<hash>/
-- node_modules/<pkg>, where the invoked package is indistinguishable BY PATH from its
-- transitive dependencies. Measured on the reference Mac: globbing that cache generically
-- returns 1938 rows, and the scoped-only variant returns 123 which are almost entirely
-- @aws-sdk, @babel and @nodelib. The old branch avoided this only by naming two packages
-- outright, which is the practice this file exists to remove.
--
-- An agent run through npx still creates its state dotdir on first run and is caught by
-- the branch above. That reasoning is UNVERIFIED -- it has not been exercised against a
-- real npx-launched agent -- so it is recorded here as a gap rather than a mitigation.
-- Scenario 55-openclaw-npm is where it would be proven.
