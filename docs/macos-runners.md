# macOS scenario runners on our own Macs

The macOS jobs of [`scenarios.yml`](../.github/workflows/scenarios.yml) can run on Macs we
own instead of GitHub's runners. Each Mac boots **a fresh VM for every job** and deletes it
afterwards. The scripts are in [`test/runner-host/`](../test/runner-host/); this page is how
to set one up and how to move jobs onto it.

## How a job gets there

The `scenario` job runs on `[self-hosted, arthur-macos-<n>]` when the repository variable
`MACOS_SCENARIO_RUNNERS` is `self-hosted`, or when a dispatch sets its `runners` input to
`self-hosted`. Anything else runs on GitHub's runners, so **deleting the variable is the way
back**. A misspelt value turns the job red rather than silently staying on GitHub. The
runners never carry GitHub's own `macos-<n>`, so a job asking for a GitHub-hosted Mac
cannot land on one of ours.

**The workflow sends a fork's pull request to GitHub's runners, but cannot enforce it.** A
pull request runs its own copy of the workflow, and a fork can edit that copy to ask for
these runners. What enforces it is the repository's approval rule: no outside
contributor's run starts until a maintainer approves it. Read a fork's workflow changes
before approving its run.

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
- **Approval for every outside contributor.** `slot.sh` also refuses unless the
  repository's approval policy is `all_external_contributors`, the one that holds every
  fork's run for a maintainer.

The runner starts inside the VM's **GUI session**, as a LaunchAgent
([`guest-agent.sh`](../test/runner-host/guest-agent.sh)), not over SSH. `50-autonomous`
runs `open -a`, which needs a GUI session, as GitHub's runners provide.

## One-time GitHub setup (an org owner)

1. **Create a GitHub App** owned by the org, with two permissions and nothing else:
   - Organization: **Self-hosted runners: Read and write**, to register runners.
   - Repository: **Administration: Read-only**, to read the approval policy. Never *Read
     and write*, which can also change this repository's settings and rulesets, or delete it.

   Install it on the org, with access to this repository. Record the App ID and the
   installation ID, and generate a private key.
2. **Restrict the org's runner group.** Org settings → Actions → Runner groups → *Default*:
   - Repository access: **Selected repositories**, this repository only.
   - Tick **Allow public repositories**.
3. **Keep the approval policy.** This repository's Settings → Actions → General → *Approval
   for running fork pull request workflows from contributors*: **Require approval for all
   external contributors**.

`slot.sh` reads all three settings before every job and refuses to register a runner
without them. If the plan offers no way to restrict the runner group, nothing registers.
That outcome is deliberate.

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
   - `slots`: one `<slot> <label>` line per VM, e.g. `a macos-15` and `b macos-26`. The
     label is the workflow's; the slot's runner registers as `arthur-macos-15`. A Mac runs
     at most two macOS VMs (Apple's license, and Virtualization.framework). Weight the
     labels towards `macos-26`, because a pull request runs the first label alone.
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
5. **Isolation, by breaking it.** Boot a clone in a window with
   `tart clone arthur-runner-15 iso && tart run --net-softnet iso`, and open Terminal in it:
   - Reaching a LAN address must fail.
   - Reaching `https://github.com` must succeed.
   - Reaching the Mac's port 22 at the gateway (`route -n get default`) must fail. If it
     answers, Remote Login is on.

   Shut it down, `tart run iso` without `--net-softnet`, and see the LAN check succeed,
   which shows the checks can fail. Then `tart delete iso`.
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
  same OS. Then, on every Mac, `host-setup.sh stop` first, because a slot clones the image
  between jobs and `bake.sh` refuses while slots are loaded:
  - On the Mac that bakes: `bake.sh 15`, which keeps the old image as `arthur-runner-15-prev`,
    then `tart export` it.
  - On the others: `tart delete arthur-runner-15-prev` if it exists, then
    `tart rename arthur-runner-15 arthur-runner-15-prev`, then `tart import` the new file as
    `arthur-runner-15`. `tart import` takes no overwrite option, as of Tart 2.41.1.
  - Then `host-setup.sh start` on each.
- The runner release refreshes itself daily, verified against its published SHA-256.
- Update each Mac's macOS by hand. Someone logs in afterwards anyway.
