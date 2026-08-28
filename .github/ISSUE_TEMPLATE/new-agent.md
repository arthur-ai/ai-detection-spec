---
name: New AI agent
about: A tool this should detect but does not know about
labels: signature
---

**Tool**

Name, vendor, link.

**How you installed it**

Homebrew cask? npm global? A `curl | bash` installer? A direct download? If several are
possible, say which you used, since each lands somewhere different.

**What it looks like on disk**

```console
$ osqueryi "SELECT bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '%NAME%'"
```

Bundle identifier, package name, install path, any launchd label, any port it listens on.

**Have you added a scenario?**

A signature needs a passing scenario under `test/scenarios/`. If you have not written one, say
so and open the issue anyway; a maintainer can help.
