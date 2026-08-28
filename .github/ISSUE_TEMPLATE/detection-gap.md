---
name: Detection gap
about: A tool the queries know about but fail to find
labels: bug
---

> **Stop:** if this is a technique for deliberately *evading* detection rather than a tool we
> simply miss, please email security@arthur.ai instead. See SECURITY.md.

**What is installed**

Tool, version, and how it was installed.

**What the query returned**

```console
$ sudo osqueryi --json < queries/discovery.sql
```

**What you expected**

Which row, with which `kind` and `id`.

**Environment**

macOS version, Apple Silicon or Intel, osquery version.
