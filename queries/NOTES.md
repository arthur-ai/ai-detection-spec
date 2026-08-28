# Deliberately absent

Tables considered and left out, with the measurements that decided it.

```
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
```
