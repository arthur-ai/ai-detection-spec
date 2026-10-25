# Mapping to other standards

This page is informative. It says where the pieces of the
[Open Agent Detection Format](SPEC.md) fit into standards a reader may already use, what does
not fit, and what would have to change elsewhere for the format to sit inside one of them. Every
field named below was read from that standard's published schema or specification.

## At a glance

| standard | what it describes | written by | relation to this format |
|---|---|---|---|
| [package-url](https://github.com/package-url/purl-spec) (ECMA-427) | a package's coordinate | package registries | **used.** Identifiers on routes that declare `purl` carry one (SPEC.md 4.3, 4.4) |
| [CycloneDX 1.6](https://cyclonedx.org/docs/1.6/json/) | a bill of materials | whoever produces the software, or scans it | **a finding fits as a component with evidence**, with the gaps below |
| [OVAL](https://oval.cisecurity.org/), `inventory` class | checks that a piece of software is installed | content authors | **the nearest existing standard.** Generic, with no agent scope and no proof |
| [OASF](https://schema.oasf.outshift.com/) (AGNTCY) | records of agents and their skills | the agent's operator | **complementary.** Its locators say where to get an agent; nothing says where it is installed |
| [SPDX 3.0](https://spdx.github.io/spdx-spec/v3.0.1/), AI profile | an AI system, as built | the builder | **complementary.** `autonomyType` is close to this format's scope test |
| [A2A](https://a2a-protocol.org/) Agent Card | how to reach and talk to a remote agent | the operator | no overlap |
| CSA Agent Registry | the agents an organisation runs | the organisation | no overlap. A finding of an unregistered agent is what a registry cannot produce |

Every standard in the last four rows is written by someone who knows the agent exists. This
format exists for the agents nobody wrote down.

## CycloneDX 1.6

A matcher's findings for one machine can be written as a CycloneDX BOM:

| this format | CycloneDX |
|---|---|
| a finding | a `component` of type `application`, named after the agent |
| the matched identifier | `evidence.identity[]`: `field` is `purl` where the identifier has one and `name` otherwise, with the identifier as `concludedValue` |
| the route the identifier sits on | `evidence.identity[].methods[].technique`, from the table below |
| an evidence row's `loc` | `evidence.occurrences[].location` |
| an open gap (SPEC.md 6.7) | a `compositions` entry whose `aggregate` is `incomplete` or `unknown`, never `complete` |
| an identifier's proof (SPEC.md 7.2) | `declarations`: an attestation whose evidence is the CI run that produced the identifier |

**What does not fit.** Every entry in `methods` requires a `confidence` between 0 and 1. This
format has none: an identifier either matched or did not, and nothing here has measured how often
a match is wrong. A value written to satisfy the schema would be a number nobody measured, so
`methods` is the field to leave out until one is.

**No property taxonomy entry yet.** Route and status could travel as `properties`. The
CycloneDX property taxonomy is where a shared name for them would be registered.

## The routes

How each route in this repository's catalog maps to package-url and to a CycloneDX technique.
`tools/check_doc_numbers.py` fails if a route in `catalog/routes.yaml` has no row here.

| route | the identifier is | CycloneDX technique | purl type |
|---|---|---|---|
| `bundle_ids` | an application's bundle id, from its `Info.plist` | `manifest-analysis` | none registered |
| `homebrew` | a Homebrew formula or cask name | `manifest-analysis` | `brew` exists, but cannot tell a cask from a formula |
| `launchd_prefixes` | the start of a launchd label | `manifest-analysis` | none |
| `running_apps` | a running application's bundle id | `dynamic-analysis` | none |
| `npm` | an npm package name | `manifest-analysis` | `npm` |
| `running_npm` | the npm package a running process runs from | `dynamic-analysis` | `npm` (through `npm`) |
| `pypi` | a PyPI distribution, from a pipx or uv directory name | `filename` | `pypi` |
| `extension_ids` | a Chrome Web Store extension id | `manifest-analysis` | `chrome-extension` |
| `native_messaging_hosts` | a native messaging host manifest's file name | `filename` | none |
| `vscode_extensions` | a VS Code marketplace id | `manifest-analysis` | `vscode-extension` |
| `jetbrains_plugins` | a JetBrains plugin directory name | `filename` | none registered |
| `images` | a container image repository | `manifest-analysis` | `docker` and `oci` exist; deferred, because tools disagree on where the registry goes |
| `container_images` | the image a running container was started from | `dynamic-analysis` | as `images` |
| `image_labels` | an image's `org.opencontainers.image.source` label | `manifest-analysis` | none: it names a source repository, not an install |
| `state_dirs` | a directory in a home directory | `filename` | none |
| `binaries` | a path in a home directory | `filename` | none |
| `process_paths` | the path a running process executes from | `dynamic-analysis` | none |
| `model_stores` | a path in a home directory | `filename` | none |
| `ports` | retired: a port identifies nothing | none | none |
| `deb_packages` | a Debian package name | `manifest-analysis` | `deb` exists, but needs the distribution as a namespace |
| `rpm_packages` | an RPM package name | `manifest-analysis` | `rpm` exists, but needs the distribution as a namespace |
| `desktop_ids` | a `.desktop` entry's file name | `filename` | none |
| `systemd_prefixes` | the start of a systemd unit name | `filename` | none |

## OVAL

OVAL's `inventory` class is the closest prior standard: a definition whose result is true when a
piece of software is installed. It differs in four ways that matter here.

- **No scope.** It describes any software. This format describes only agents, and says why
  (SPEC.md 3).
- **Different tests.** OVAL's tests read package databases, files, property lists, processes
  and, on Windows, the registry. Several of this format's routes have no OVAL test: npm globals,
  browser and editor extensions, and container images.
- **No proof.** A definition says how to detect something, not which installation showed that
  the check works.
- **No agreed answer for an unread source.** This format makes "could not look" a different
  answer from "found nothing" (SPEC.md 5.2).

Identifiers on the `deb_packages`, `rpm_packages` and path routes could be rendered as OVAL
inventory definitions for the platforms OVAL covers.

## OASF

An OASF record carries `name`, `version`, `description`, `authors`, `skills`, `domains`,
`locators` and `modules`. A record's `locators` have the types `binary`, `container_image`,
`helm_chart`, `package`, `source_code` and `url`. They say where an agent can be obtained, which
for a package is close to this format's identifiers. Nothing in a record says what an
installation leaves on a machine: a bundle id, a state directory, a launchd label, a browser
extension id.

OASF extends a record through `modules`. A module carrying a catalog entry's identifiers, with
their match modes and their proof, is the natural way for an OASF record to say how its agent is
found on an endpoint. This is a proposal only. Nothing has been filed.

## SPDX 3.0

The AI profile's `AIPackage` has `autonomyType`, "whether the system can perform a decision or
action without human involvement or guidance" (`yes`, `no` or `noAssertion`). That is close to
this format's test for what counts as an agent. A builder who sets it to `yes` is saying their
package would belong in a catalog of this format. The two describe different moments:
SPDX describes the package as built, and this format describes the machine it was installed on.

## Where this could go

Recorded rather than acted on: an OASF module, as above; names for this format's route and status
in the CycloneDX property taxonomy; and the AI Agent Standards Initiative at NIST's Center for AI
Standards and Innovation. Nothing goes upstream without a decision to send it.
