# macOS scenario runners on our own Macs

The macOS jobs of [`scenarios.yml`](../.github/workflows/scenarios.yml) can run on Macs we
own instead of GitHub's runners. Each Mac boots **a fresh VM for every job** and deletes it
afterwards. The scripts are in [`test/runner-host/`](../test/runner-host/); this page is how
to set one up and how to move jobs onto it.

## How a job gets there

The `scenario` job runs on `[self-hosted, macos-<n>]` when the repository variable
`MACOS_SCENARIO_RUNNERS` is `self-hosted`, or when a dispatch sets its `runners` input to
`self-hosted`. Anything else runs on GitHub's runners, so **deleting the variable is the way
back**. A misspelt value turns the job red rather than silently staying on GitHub.

**A pull request from a fork always runs on GitHub's runners.** This repository is public,
and a self-hosted runner runs whatever a pull request writes into the workflow.

## What keeps a job contained

- **A new VM per job.** Scenarios install real software and `00-baseline` asserts a clean
  machine, so no disk is reused. [`slot.sh`](../test/runner-host/slot.sh) clones the
  label's image, boots it, and deletes the clone when the job ends.
- **A single-use runner.** It is registered just in time for one job, and it deregisters itself afterwards.
- **No secrets in the VM.** The GitHub App key stays on the host. The VM gets two read-only
  folders: the runner release and its own one-job registration.
- **Softnet.** The VM can reach the internet but not private addresses. **Softnet does let a
  VM reach the bridge's gateway, which is the Mac itself**, so any service listening on all
  interfaces is reachable from a job. `host-setup.sh configure` lists them. Turn off Remote
  Login and every other listener you do not need.
- **A runner group limited to this repository.** The runners are org runners, and `slot.sh`
  refuses to register one unless the group serves this repository alone. A group open to the
  whole org would let any public repository in it send jobs to these Macs.

The runner starts inside the VM's **GUI session**, as a LaunchAgent
([`guest-agent.sh`](../test/runner-host/guest-agent.sh)), not over SSH. `50-autonomous`
runs `open -a`, which needs a GUI session, as GitHub's runners provide.

## One-time GitHub setup (an org owner)

1. **Create a GitHub App** owned by the org, with the organization permission **Self-hosted
   runners: Read and write** and nothing else. Install it on the org.
   - Record the App ID and the installation ID, and generate a private key.
   - Do not grant it the repository permission *Administration*. That permission can also
     change this repository's settings and rulesets, or delete it.
2. **Restrict the org's runner group.** Org settings → Actions → Runner groups → *Default*:
   - Repository access: **Selected repositories**, this repository only.
   - Tick **Allow public repositories**.

   `slot.sh` reads both settings before every job and refuses to register a runner without
   them. If the plan offers no such setting, nothing registers. That outcome is deliberate.

## A Mac

**It needs:**
- Apple silicon and macOS 26 or newer. Softnet needs 26, and a guest cannot be newer than its host.
- FileVault on, and a screen lock with a password.
- Homebrew.

**FileVault rules out auto-login.** After any reboot, a person logs in before the Mac takes
jobs again. That is deliberate for a Mac in a shared building. The login keychain must stay
unlocked, because Tart cannot start a VM without it. A locked *screen* leaves it unlocked,
so jobs keep running behind the lock.

**On Wi-Fi it must rejoin by itself.** A network that takes one shared password, or that
admits a registered hardware address, does. For the second kind, turn *Private Wi-Fi
address* off for that network before registering the address. A captive portal does not
rejoin unattended. VMs reach the network through the Mac's own address, so only the Mac
needs registering.

1. Clone this repository **at a release tag**; a host never tracks `main`.
2. Put three files in `~/.config/arthur-runner/`:
   - `app.pem`: the App's private key.
   - `app.env`: `APP_ID=…`, `INSTALLATION_ID=…`, and `RUNNER_GROUP_ID=1` for the Default group.
   - `slots`: one `<slot> <label>` line per VM, e.g. `a macos-15` and `b macos-26`. A Mac runs
     at most two macOS VMs (Apple's license, and Virtualization.framework). Weight the
     labels towards `macos-15`, because a pull request runs the first label alone.
3. `test/runner-host/host-setup.sh configure`. It checks FileVault and the screen lock. It
   turns the firewall on and sleep off, and stops the keychain from auto-locking. It also
   installs Tart and Softnet, makes Softnet setuid root, and writes one LaunchAgent per slot.
   **Run it again after a Homebrew upgrade of softnet**, which drops the setuid bit.
4. **Images.**
   - On one Mac: `test/runner-host/bake.sh 15` and `bake.sh 26`. Each pulls a pinned
     Cirrus Labs base image and adds Homebrew python3, the guest agent and no software updates.
     It keeps the result only after a second boot finds the agent running in the GUI session.
   - Copy to the others: `tart export arthur-runner-15 /Volumes/<ssd>/arthur-runner-15.tvm`,
     then `tart import <file> arthur-runner-15` on each.
5. **Isolation, by breaking it.** Boot a clone with `tart run --net-softnet`. Inside it:
   - Reaching a LAN address must fail.
   - Reaching `https://github.com` must succeed.
   - Reaching the Mac's port 22 at the gateway (`route -n get default`) must fail. If it
     answers, Remote Login is on.

   Repeat without `--net-softnet` to see the checks can fail.
6. `test/runner-host/host-setup.sh start`. Each slot appears under the repository's
   Settings → Actions → Runners while its VM waits for a job.

`host-setup.sh status` shows the slots, the VMs and the cached runner version. `stop`
unloads the slots and cuts off a running job. Logs are in `~/Library/Logs/arthur-runner/`.

## Moving jobs over

1. **Canary.** From a branch, dispatch *Scenarios* with `runners: self-hosted` and
   `scenarios: 00-baseline 50-autonomous 45-claude-extension`. Those three cover the clean
   machine, `open -a` and a browser launch. Each job's first step prints the runner's name
   and macOS version.
2. **Compare.** Dispatch the same branch twice, once with `runners: self-hosted` and once
   with `hosted`. Download each run's `observed-*` artifacts and compare them per label: the
   same identifiers, and the same pass or skip for every scenario. Explain a difference
   before moving on, rather than averaging it away.
3. Set `MACOS_SCENARIO_RUNNERS=self-hosted` in the repository's Actions variables.

A job with no runner online waits up to a day, and then fails. `collect` waits for it.

## Keeping it current

- Move a base image by reading the new digest from `ghcr.io` and editing it in `bake.sh`.
  Do it when GitHub's hosted images move a macOS release, so both kinds of runner record the
  same OS. Then bake, export, import, and `host-setup.sh stop`/`start`. `bake.sh` refuses
  while slots are loaded.
- The runner release refreshes itself daily, verified against its published SHA-256.
- Update each Mac's macOS by hand. Someone logs in afterwards anyway.
