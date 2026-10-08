# Crewline Installer

This public repository contains the phased bootstrap installer for the
private Crewline application.

It does not contain Crewline source code, container images, secrets,
certificates, databases, media, or backups.

## Supported platform

- Debian 13
- AMD64
- Root installation
- Interactive terminal
- Clean Crewline installation

## Install

Run as `root` over an existing SSH key login on a clean Debian 13 VPS.
Do not run the new source until a compatible Crewline release and this public
installer revision have been published. Publishing is a separate human action.

The release publisher supplies two public values: an approved 40-character
installer commit SHA and the SHA-256 of `install.sh` at that exact commit.
Replace both placeholders below with those values (not a branch name or tag):

```bash
(
    set -Eeuo pipefail
    umask 077
    entry_directory="$(mktemp -d /tmp/crewline-entry-download.XXXXXX)"
    trap 'rm -rf -- "$entry_directory"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --connect-timeout 10 --max-time 120 --output "$entry_directory/entry.sh" https://raw.githubusercontent.com/randomNameThatIsAvailable/crewline-installer/APPROVED_COMMIT_SHA/entry.sh
    test -s "$entry_directory/entry.sh"
    bash "$entry_directory/entry.sh" APPROVED_COMMIT_SHA INSTALL_SH_SHA256
)
```

`entry.sh` downloads the approved immutable installer over HTTPS, verifies its
expected SHA-256 before executing it, and preserves the interactive terminal.
The entry script itself must also be fetched from that approved immutable revision.
The installer automatically selects the newest complete published Crewline release
compatible with both `host-nginx-http-v1` and `resume-v1`,
including release candidates.

No Crewline release version must be supplied. The public installer revision is
deliberately pinned, rather than silently running whatever happens to be on `main`.

Download the entry script successfully before executing it, as shown above.
This prevents a failed download from appearing to be a successful empty Bash run.
Do not use:

```bash
curl URL | bash
```

The installer requires an interactive terminal so that credentials are not
placed in the command line.

## What the installer does

The installer:

1. Validates Debian 13 and AMD64.
2. Enables UFW default-deny inbound for IPv4/IPv6 before Docker or nginx installation, preserving the effective live SSH port and configured SSH listeners. It does not reset an unrelated firewall policy or modify SSH configuration.
3. Installs Docker Engine and Docker Compose when necessary.
4. Requests and validates read-only GitHub credentials.
5. Fetches release asset lists and selects the newest complete `host-nginx-http-v1` / `resume-v1` Crewline release, including release candidates. Legacy or non-resumable releases are skipped.
6. Downloads and verifies the release archive.
7. Rejects unsafe archive paths and archive links.
8. Configures Crewline for `ceremlin.mirrorcloudcenter.com`.
9. Validates the archive manifest against the selected manifest and runs Crewline's private installation script, including its loopback HTTP gateway on `127.0.0.1:18080`.
10. Preserves credentials under `/root/.config/crewline`.
11. Keeps an independent bootstrap lock and root-only atomic progress records. Recovery reuses the selected tag, image digests, hostname, ports and archive checksum; relevant operations are rerun rather than trusting progress flags. The manifest, target settings and checksum are committed together in `bootstrap/release-pin` only after checksum, archive-path and archive-manifest validation. The deployment lock also covers application file copying and the private installation script.
12. Configures host nginx for ACME HTTP validation, obtains a certificate with interactive Certbot account/consent setup, and activates public HTTPS through Crewline's host-nginx helper.
13. Enables automatic certificate renewal and nginx reload after renewal.
14. Installs Tailscale from its official Debian 13 stable package repository and allows up to 180 seconds for interactive authentication; existing authenticated nodes are retained without resetting their preferences.
15. Installs the pinned 3x-ui release archive directly, without executing the upstream installer, issuing standalone certificates, printing credentials or starting the panel with default credentials.
16. Initializes the panel database offline with random credentials and a random base path, then starts its managed service on `127.0.0.1:2053`. Subscriptions are disabled, with their reserved address set to `127.0.0.1:2096`.
17. Configures persistent Tailscale Serve HTTPS on port `9443`, preserving unrelated Serve configuration and refusing conflicting or public Funnel configuration on that port.
18. Checks the panel response, loopback listener, disabled subscription listener, persistent service/Serve configuration and VPS-local tailnet HTTPS response before reporting completion. Authentication or HTTPS enablement still pending stops the installer with retained recovery state.

The installer does not configure in this slice:

- Xray VPN transport or a VPN listener on reserved port `8443` (deferred until requested and decided)
- System-maintenance policies
- Backups
- Previously existing Crewline installations not owned by this bootstrap

Previously existing installations must use Crewline's private update mechanism.
Bootstrap recovery is allowed only for its own installation, with the same frozen
release and original `.env`; it never resets secrets. Normal updates and rollback
retain their existing deployment records and HTTP-gateway compatibility checks.
Publish a compatible release from the Slice 2 Crewline source before using this
installer; old assets must not simply be relabeled.

## Required GitHub credentials

Crewline uses two separate credentials because private repository releases and
private GHCR images use different GitHub permission systems.

### Private repository token

Create a fine-grained personal access token:

1. Open:
   <https://github.com/settings/personal-access-tokens/new>
2. Select the resource owner containing Crewline.
3. Select only the private `crewline` repository.
4. Grant repository permission:
   `Contents: Read-only`
5. Do not grant write, Actions, Administration, Secrets, or Workflows access.
6. Create and copy the token.

The installer validates and stores it at:

```text
/root/.config/crewline/github-token
```

### Private GHCR token

Create a personal access token (classic):

1. Open:
   <https://github.com/settings/tokens/new?scopes=read:packages>
2. Grant only:
   `read:packages`
3. Create and copy the token.

The installer validates the token by authenticating Docker to `ghcr.io` and
stores it at:

```text
/root/.config/crewline/ghcr-token
```

Both token files are owned by `root` with permissions `0600`.

## Safety behavior

The installer refuses to take over an existing Crewline installation. A root-only
bootstrap ownership record permits recovery of its own interrupted installation.
Its state is separate from `.crewline-deployment/current.env`, which remains
owned by Crewline's deployment tooling.

For recovery, rerun the same approved installer revision and checksum. Do not
delete `.env`, token files, Docker volumes, or bootstrap state. If a pinned release
manifest or checksum changes, recovery stops for investigation instead of changing
the target halfway through installation.

Recovery also checks the original installer content checksum. Existing legacy
`bootstrap/release.env`, `bootstrap/target` and `bootstrap/archive.sha256` records
are retained and checked before promotion to a complete `bootstrap/release-pin`.
Uncommitted `release-pin.pending.*` directories are ignored. An interrupted first
download before the pin is committed may select a newer compatible release on retry;
application files and services have not yet been installed at that point.
If a later normal update has changed the deployed release, bootstrap recovery stops
instead of copying the older pinned release over it.

New `.env` files and managed nginx files are published atomically, avoiding partially
written active files. Handled interruption signals run cleanup; forced termination
may leave temporary files, which are not used as committed recovery state. These
guarantees cover process interruption; power-loss durability has not been verified.
If Certbot or HTTPS activation fails after the temporary ACME site is installed,
handled cleanup restores the prior managed site (or removes the temporary site
when none existed) and attempts to reload nginx. Forced termination cannot run
that cleanup; rerunning the pinned installer revalidates and completes the phase.

Public IPv4 DNS for `ceremlin.mirrorcloudcenter.com` must point to this VPS (or
a proxy that forwards ACME requests to it), and provider filtering must allow
inbound 80/443. The installer does not modify DNS or provider firewall rules.
Certbot obtains certificates through nginx webroot, never standalone port binding.
Only Crewline-managed nginx configuration and renewal hooks may be replaced.

The final handoff distinguishes checks performed on the VPS from access on another
tailnet device. A local success does not verify phone access, public Internet
reachability or resolution of the earlier external Crewline network problem.

## Private Tailscale / 3x-ui access

The inspected upstream 3x-ui release is pinned to:

- Release: `v3.9.0`
- Source commit: `3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb`
- Inspected upstream `install.sh` SHA-256: `18616fe26c8f6c92db6daa2dcd7cd53c5143ee69ecfd26d8ea6dc9b2c78607a6`
- AMD64 archive SHA-256: `d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390`

Sources: [3x-ui release](https://github.com/MHSanaei/3x-ui/releases/tag/v3.9.0),
[inspected installer](https://github.com/MHSanaei/3x-ui/blob/3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb/install.sh),
[official Debian package instructions](https://pkgs.tailscale.com/stable/#debian-trixie),
and [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve).

The installer verifies the archive against the fixed digest before extraction.
The upstream installer is inspection evidence only; it is not executed. The panel
binary initializes a temporary offline SQLite database; Python's Debian bcrypt
package hashes random credentials, which are committed before the managed
`x-ui.service` starts. No password is supplied as a command-line argument.
No upstream default account is exposed to the tailnet.

Private recovery ownership and initial credentials are root-owned under:

```text
/root/.config/crewline/bootstrap/private-access/pin.json
/root/.config/crewline/bootstrap/private-access/initial-panel.json
/root/.config/crewline/bootstrap/private-access/current-access.json
```

The directory is mode `0700`; these files are mode `0600`. Only their location is
printed. Recovery reuses the original initial values and preserves later panel
credential/base-path changes in the database. It does not reset them. It refuses
unowned installations, changed pinned panel binaries, service overrides, default
credentials or pre-existing VPN inbounds. No automatic panel upgrade is performed.
`current-access.json` is written only after a successful VPS-local HTTPS probe;
it records the current HTTPS origin and database base path. `initial-panel.json`
continues to describe the initial credentials even after the human changes them.

Authentication and tailnet HTTPS consent can require human action. The installer
allows bounded confirmation rather than claiming success while waiting. After
completing a pending action, rerun the same published installer revision. Keep the
private state, panel database and binaries. Interrupted package configuration can
be reused only when it matches the official downloaded package configuration.

Serve uses `--bg --https=9443 http://127.0.0.1:2053`; it does not reset Serve or
enable Funnel. The installer does not open public firewall ports `2053`, `2096`,
`9443` or `8443`, or alter Tailscale's firewall-management mode. Host nginx continues
to own public `80/443`.

After installation, replace the initial panel credentials, restrict tailnet access
to this node and port `9443`, and consider disabling the server's machine-key expiry.
Verify the panel from a phone or another authorized tailnet device. SSH tunnelling
to VPS `127.0.0.1:2053` remains the fallback; use the panel's protected base path.
No VPN protocol/transport has been selected or configured.

Source-contract regression checks (no services are installed):

```bash
python3 -m unittest test_bootstrap
bash -n entry.sh
bash -n install.sh
```

In the private Crewline checkout, also run `python3 -B -m unittest
ci.test_configure_environment`, `bash -n install.sh` and `bash -n enable-https.sh`.
The real atomic `.env` publication check runs on Linux; Windows skips it.

It does not automatically delete existing Crewline data after a failure.
