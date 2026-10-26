---
name: New AI agent
about: A tool this should detect but does not know about
labels: signature
---

**Tool**

Name, vendor, link.

**Which platform, and how you installed it**

macOS or Linux, and by which route: Homebrew cask, npm global, `.deb`, `.rpm`, AppImage, a
`curl | bash` installer, a direct download, a VS Code extension? If several are possible, say
which you used, since each lands somewhere different — and a single agent commonly needs an
entry for each.

**What it looks like on disk**

Read the identifier off the install rather than off the vendor's page. That is not pedantry:
`bot.molt.mac` came from OpenClaw's own Homebrew metadata and matched nothing on any Mac.

```console
# macOS
$ osqueryi "SELECT bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '%NAME%'"
$ osqueryi "SELECT name, version, type FROM homebrew_packages WHERE name LIKE '%NAME%'"

# Linux -- note the status filter: dpkg keeps a record for a package that was removed
# but not purged, so without it you may be reading something nobody has installed.
$ osqueryi "SELECT name, version, status FROM deb_packages WHERE status LIKE '%ok installed' AND name LIKE '%NAME%'"
$ osqueryi "SELECT name, version, vendor FROM rpm_packages WHERE name LIKE '%NAME%'"
$ osqueryi "SELECT filename, path FROM file WHERE path LIKE '/usr/share/applications/%.desktop'"

# Either platform
$ osqueryi "SELECT name, version FROM npm_packages WHERE name LIKE '%NAME%'"
$ osqueryi "SELECT name, version, vscode_edition FROM users CROSS JOIN vscode_extensions USING (uid)"
$ osqueryi "SELECT name, vendor, version, path FROM users CROSS JOIN jetbrains_plugins USING (uid)"
```

Package name, install path, any launchd label or systemd unit, any state directory it creates
on first run. For a VS Code extension the identifier is the `name` column alone — `publisher_id`
is a GUID, not the publisher slug. For a JetBrains plugin it is the last component of `path`,
the plugin's directory.

**Have you added a scenario?**

An identifier needs a passing scenario under `test/scenarios/`. If you have not written one,
say so and open the issue anyway; a maintainer can help.
