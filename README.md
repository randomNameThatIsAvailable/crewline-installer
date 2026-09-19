# Crewline Installer

This public repository contains the minimal bootstrap installer for the
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

Run as `root` on a clean Debian 13 VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/randomNameThatIsAvailable/crewline-installer/main/install.sh)
```

This command always downloads the current installer from `main`. The installer
then automatically selects the newest complete published Crewline release,
including release candidates.

No installer version or Crewline release version must be supplied.

Use process substitution exactly as shown. Do not use:

```bash
curl URL | bash
```

The installer requires an interactive terminal so that credentials are not
placed in the command line.

## What the installer does

The installer:

1. Validates Debian 13 and AMD64.
2. Installs required Debian packages.
3. Installs Docker Engine and Docker Compose when necessary.
4. Requests and validates read-only GitHub credentials.
5. Selects the newest complete Crewline release, including release candidates.
6. Downloads and verifies the release archive.
7. Rejects unsafe archive paths and archive links.
8. Configures Crewline for `ceremlin.mirrorcloudcenter.com`.
9. Runs Crewline's private installation script.
10. Preserves credentials under `/root/.config/crewline`.

The installer does not configure:

- TLS certificates
- Public Nginx HTTPS routing
- System-maintenance policies
- Backups
- Existing Crewline installations

Existing installations must use Crewline's private update mechanism instead.

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

The installer refuses to overwrite an existing Crewline installation. It stops
when it detects an existing Crewline environment file, project directory, or
database volume.

It does not automatically delete existing Crewline data after a failure.