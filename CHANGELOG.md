# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org), with repository-specific meaning:

- **major** — the six-column contract or the catalog schema changes. Consumers must change code.
- **minor** — a new query, or new signatures. Additive and safe to take.
- **patch** — a corrected identifier, a fixed glob, documentation.

Releases are cut whenever signatures change, at most weekly.

**Identifiers are corrected, not removed.** When a vendor changes a bundle id, machines that
installed the earlier version still carry the old one, so it is kept as an alias.

## [Unreleased]

## [0.1.0]

Initial release.

### Added
- `queries/discovery.sql`, detecting desktop AI apps, CLI agents, npm and PyPI installs,
  Homebrew packages, browser extensions with permissions, native messaging hosts, launchd
  persistence, local inference ports and Ollama model stores.
- Test harness with nine scenarios covering every row kind the query emits.
- `test/lint.sh`: statement count, per-branch column width, kind coverage, `COALESCE` on
  aggregates, and a check for dangling `UNION ALL`.
